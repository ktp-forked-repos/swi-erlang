/*  Part of SWI-Prolog

    Author:        Jan Wielemaker
    E-mail:        J.Wielemaker@vu.nl
    WWW:           http://www.swi-prolog.org
    Copyright (c)  2017, VU University Amsterdam
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions
    are met:

    1. Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in
       the documentation and/or other materials provided with the
       distribution.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
    FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
    COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
    INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
    BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
    LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
    LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
    ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
*/

:- module(dispatch,
          [ start/0,
            flush/0,
            spawn/1,                    % :Goal
            spawn/2,                    % :Goal, -Id
            spawn/3,                    % :Goal, -Id, +Options
            send/2,                     % +Id, +Message
            (!)/2,			% +Id, +Message
            exit/1,                     % +Reason
            exit/2,                     % +Id, +Reason
            receive/1,                  % +Clauses
            link/2,                     % +Parent, +Child
            self/1,                     % -Id
            register/2,                 % +Alias, +Pid
            unregister/1,		% +Alias

            dump_backtrace/2,           % +Id, +Depth
            dump_queue/2,               % +Id, -Queue

            op(1000, xfx, when),
            op(800, xfx, !)
          ]).
:- use_module(library(debug)).
:- use_module(library(option)).
:- use_module(library(lists)).
:- use_module(library(time)).
:- use_module(library(error)).

:- meta_predicate
    spawn(0),
    spawn(0, -),
    spawn(0, -, +),
    receive(:).

% :- debug(dispatch).

:- multifile
    hook_self/1,
    hook_spawn/3,
    hook_send/2,
    hook_goal/3.


		 /*******************************
		 *             STATE		*
		 *******************************/

:- dynamic
    registered/3,                       % Name, Parent, Child
    dispatch_queue/1,
    worker/1,
    linked_child/2,                     % Parent, Child
    exit_reason/2.                      % Pid, Reason


		 /*******************************
		 *           CONTROL		*
		 *******************************/

%!  start is det.
%!  start(+Options) is det.
%
%   Start the message dispatcher for the current process. Options are:
%
%     - queues(+Count)
%     Number of queues used to dispatch messages.  Currently must
%     be `1`.
%     - workers(+Count)
%     Number of workers used to activate engines.  Default `5`.
%
%   @tbd Use multiple queues

start :-
    start([]).

start(_) :-
    dispatch_queue(_),
    !.
start(Options) :-
    option(queues(Queues), Options, 1),
    option(workers(Workers), Options, 5),
    make_dispatch_queues(Queues),
    make_workers(Workers).


make_dispatch_queues(N) :-
    forall(between(1, N, _),
           (   message_queue_create(Queue, []),
               assertz(dispatch_queue(Queue))
           )).

next_dispatch_queue(Q) :-
    dispatch_queue(Q).

make_workers(N) :-
    dispatch_queue(Queue),
    forall(between(1, N, I),
           (   atom_concat(dispatch_, I, Alias),
               thread_create(work(Queue), Tid, [alias(Alias)]),
               assertz(worker(Tid))
           )).

work(Queue) :-
    thread_get_message(Queue, event(Pid, Type, Message)),
    debug(dispatch(queue), 'Got ~p', [event(Pid, Type, Message)]),
    (   dispatch_event(Pid, Type, Message)
    ->  true
    ;   debug(dispatch(dispatch), 'FAILED ~p', [event(Pid, Type, Message)])
    ),
    work(Queue).

dispatch_event(Pid, user, Message) :-
    nonvar(Message),
    Message = '$exit'(Reason),
    !,
    exit_engine(Pid, Reason).
dispatch_event(Pid, user, Message) :-
    catch(post_true(Pid, Message), E,
          post_failed(E, Pid, Message)).

post_failed(_, _, after(_)) :-
    !.
post_failed(_, Pid, _) :-
    exit_reason(Pid, _),
    !.
post_failed(E, Pid, Message) :-
    (   debugging(dispatch(delivery))
    ->  Level = warning
    ;   Level = silent
    ),
    print_message(Level, actor(delivery_failed(Pid, Message, E))).

post_true(Pid, Message) :-
    debug(dispatch(wakeup), 'Wakeup ~p for ~p', [Pid, Message]),
    engine_post(Pid, Message, Reply),
    debug(dispatch(wakeup), 'Wakeup ~p replied ~p', [Pid, Reply]),
    (   nonvar(Reply),
        Reply = timeout(TimeOut, Deadline)
    ->  schedule_timeout(Pid, TimeOut, Deadline)
    ;   assertion(Reply == true)
    ).

%!  exit(+Reason)
%
%   Exit the current process.

exit(Reason) :-
    self_local(Self),
    asserta(exit_reason(Self, Reason)),
    abort.

%!  exit(+Pid, +Reason)

exit(Pid, Reason) :-
    send(Pid, '$exit'(Reason)).

%!  exit_engine(+Pid) is det.
%!  exit_engine(+Pid, +Reason) is det.
%
%   Cause a process to exit with Reason.
%
%   @bug Currently stops a possibly running   engine using the exception
%   `abort`.    Eventually,    this    should     use    abort/0,    but
%   engine_next_reified/2 is based on catch/3 and  thus cannot catch the
%   aborted exception.

exit_engine(Pid, Reason) :-
    asserta(exit_reason(Pid, Reason)),
    catch(exit_engine(Pid),
          error(existence_error(_,_), _),
          true).

exit_engine(Pid) :-
    thread_property(Pid, engine(true)),
    (   thread_property(Pid, status(running))
    ->  debug(dispatch(exit), 'Aborting engine ~p', [Pid]),
        catch(thread_signal(Pid, throw(abort)), _, true),
        engine_next_reified(Pid, _0Status),
        debug(dispatch(exit), 'Status: ~p~n', [_0Status])
    ;   true
    ),
    engine_destroy(Pid).
exit_engine(Pid) :-
    debug(dispatch(exit), 'Aborting thread ~p', [Pid]),
    thread_signal(Pid, abort),
    thread_join(Pid, Status),
    debug(dispatch(exit), 'Status: ~p~n', [Status]).


		 /*******************************
		 *           TIMEOUT		*
		 *******************************/

%!  schedule_timeout(+Pid, +TimeOut, +Deadline)
%
%   Add a timeout(TimeOut) message to the queue of Pid at Deadline.

schedule_timeout(Pid, TimeOut, Deadline) :-
    catch(thread_send_message(scheduler, timeout(Pid, TimeOut, Deadline)),
          error(existence_error(message_queue, scheduler), _),
          with_mutex(scheduler,
                     schedule_timeout_start(Pid, TimeOut, Deadline))).

schedule_timeout_start(Pid, TimeOut, Deadline) :-
    start_scheduler,
    thread_send_message(scheduler, timeout(Pid, TimeOut, Deadline)).

start_scheduler :-
    thread_create(scheduler, _, [alias(scheduler), detached(true)]).

scheduler :-
    thread_get_message(Message),
    schedule(Message),
    scheduler.

schedule(timeout(Pid, TimeOut, Deadline)) :-
    alarm_at(Deadline, send(Pid, after(TimeOut)), _,
             [ remove(true)
             ]).


		 /*******************************
		 *            PROCESSES		*
		 *******************************/

%!  spawn(:Goal) is det.
%!  spawn(:Goal, -Pid) is det.
%!  spawn(:Goal, -Pid, +Options) is det.
%
%   Spawn a new process.  Options:
%
%     - monitor(+BoolOrPid)
%       Send monitor events to the creator if the argument is `true`
%       or the provided `Pid`.
%     - link(+Bool)
%       If true, exit the spawned process if we exit.
%     - alias(+Atom)
%       Register the process under this name.

spawn(Goal) :-
    spawn(Goal, _, []).

spawn(Goal, Engine) :-
    spawn(Goal, Engine, []).

spawn(Goal, Engine, Options) :-
    hook_goal(Goal, Goal1, Options),
    !,
    spawn2(Goal1, Engine, Options).
spawn(Goal, Engine, Options) :-
    spawn2(Goal, Engine, Options).

spawn2(Goal, Engine, Options) :-
    select_option(monitor(true), Options, Options1),
    !,
    self(Me),
    spawn3(Goal, Engine, [monitor(Me)|Options1]).
spawn2(Goal, Engine, Options) :-
    spawn3(Goal, Engine, Options).

spawn3(Goal, Engine, Options) :-
    select_option(alias(Alias), Options, Options1),
    !,
    spawn4(Goal, Engine, Options1),
    register(Alias, Engine).
spawn3(Goal, Engine, Options) :-
    spawn4(Goal, Engine, Options).

spawn4(Goal, Engine, Options) :-
    hook_spawn(Goal, Engine, Options),
    !.
spawn4(Goal, Engine, Options) :-
    engine_create(true, run(Goal, Options), Engine, Options),
    (   option(link(true), Options)
    ->  self(Me),
        link(Me, Engine)
    ;   true
    ),
    send(Engine, '$start').

self(Pid) :-
    hook_self(Me),
    !,
    Me = Pid.
self(Pid) :-
    self_local(Pid).

self_local(Pid) :-
    engine_self(Me),
    !,
    Me = Pid.
self_local(thread(Tid)) :-
    thread_self(Tid).

run(Goal, Options) :-
    setup_call_catcher_cleanup(
        true,
        once(Goal),
        Catcher,
        down(Catcher, Options)).

down(Reason, Options) :-
    down_reason(Reason, Reason1),
    self(Self),
    debug(dispatch(down), '~p down on ~p', [Self, Reason1]),
    (   option(monitor(Pid), Options)
    ->  send(Pid, down(Self, Reason1))
    ;   true
    ),
    self_local(SelfLocal),
    retractall(registered(_, _, SelfLocal)),
    destroy_children(Self).

down_reason(_, Reason) :-
    self_local(Self),
    retract(exit_reason(Self, Reason)).
down_reason(Reason, Reason).

destroy_children(Me) :-
    forall(retract(linked_child(Me, Child)),
           exit(Child, normal)).

%!  link(+Parent, +Child) is det.
%
%   Define that if Parent goes down, Child is destroyed.

link(Parent, Child) :-
    assertz(linked_child(Parent, Child)).

receive(Clauses) :-
    process_queue(Queue0),
    self(Self),
    debug(dispatch(receive), '~p queue: ~p', [Self, Queue0]),
    (   select(Message, Queue0, Queue1),
        receive_clause(Clauses, Message, Body)
    ->  b_setval(event_queue, Queue1),
        call_body(Clauses, Body)
    ;   timeout(Clauses, Time)
    ->  debug(dispatch(timeout), '~p: wait for ~p sec.', [Self, Time]),
        process_get_message(New, Time),
        b_setval(event_queue, [New|Queue0]),
        receive(Clauses)
    ;   process_get_message(New),
        b_setval(event_queue, [New|Queue0]),
        receive(Clauses)
    ).

call_body(M:_, Body) :-
    debug(dispatch(call), 'Calling ~p', [M:Body]),
    (   call(M:Body)
    *-> true
    ;   format('Body failed: ~p~n', [Body])
    ).

process_queue(Queue) :-
    nb_current(event_queue, Queue),
    !.
process_queue([]).

%!  process_get_message(-Message) is det.
%!  process_get_message(-Message, +TimeOut, -TimedOut)
%
%   Wait for a message.  If  no   message  arrived  before TimeOut unify
%   TimedOut with `true`.

process_get_message(Message) :-
    engine_self(_),
    !,
    (   nb_current(event_queue, _)
    ->  engine_yield(true)
    ;   b_setval(event_queue, [])
    ),
    engine_fetch(Message0),
    service_message(Message0, Message).
process_get_message(Message) :-
    thread_get_message(!(Message)).

process_get_message(Message, TimeOut) :-
    TimeOut =:= 0,
    !,
    self(Self),
    send(Self, after(TimeOut)),
    process_get_message(Message).
process_get_message(Message, TimeOut) :-
    engine_self(_),
    !,
    (   nb_current(event_queue, _)
    ->  get_time(Now),
        Deadline is Now+TimeOut,
        engine_yield(timeout(TimeOut, Deadline))
    ;   b_setval(event_queue, [])
    ),
    engine_fetch(Message0),
    (   nonvar(Message0),
        Message0 = after(_)
    ->  Message = Message0
    ;   service_message(Message0, Message)
    ).
process_get_message(Message, TimeOut) :-
    thread_self(Self),
    (   thread_get_message(Self, !(Message), [timeout(TimeOut)])
    ->  true
    ;   Message = after(TimeOut)
    ).

service_message(Message0, Message) :-
    nonvar(Message0),
    service_message2(Message0, Reply), !,
    engine_yield(Reply),
    engine_fetch(Message1),
    service_message(Message1, Message).
service_message(Message, Message).

service_message2(after(TimeOut), true) :-
    TimeOut > 0.
service_message2('$start', true).
service_message2('$backtrace'(Depth), true) :-
    set_prolog_flag(backtrace_goal_depth, 10),
    backtrace(Depth).
service_message2('$queue', Queue) :-
    process_queue(Queue).


receive_clause(_M:{Clauses}, Message, Body) :-
    receive_clause2(Clauses, Message, Body).

receive_clause2((C1;C2), Message, Body) :-
    !,
    (   receive_clause2(C1, Message, Body)
    ;   receive_clause2(C2, Message, Body)
    ).
receive_clause2((HeadAndGuard -> Body), Message, Body) :- !,
    (   subsumes_term(when(Head,Guard), HeadAndGuard)
    ->  when(Head,Guard) = HeadAndGuard,
        subsumes_term(Head, Message),
        Head = Message,
        call(Guard)
    ;   subsumes_term(HeadAndGuard, Message),
        HeadAndGuard = Message
    ),
    debug(dispatch(match), 'Message: ~p, body: ~p', [Message, Body]).

%!  timeout(:Clauses, -Timeout) is semidet.
%
%   True when Clauses contains a after(TimeOut) message.

timeout(_M:{Clauses}, Timeout) :-
    timeout(Clauses, Timeout).

timeout((C1;C2), Timeout) :-
    !,
    (   timeout(C1, Timeout)
    ->  true
    ;   timeout(C2, Timeout)
    ).
timeout((After -> _Body), Timeout) :-
    subsumes_term(after(_), After),
    after(Timeout) = After.


%!  send(+Pid, +Message) is det.
%!  !(+Pid, +Message) is det.
%
%   Send Message to Pid.

Pid ! Message :-
    send(Pid, Message).

send(Pid, Message) :-
    (   var(Message)
    ->  instantiation_error(Message)
    ;   var(Pid)
    ->  instantiation_error(Pid)
    ).
send(Alias, Message) :-
    registered(Alias, SelfLocal, Pid),
    self_local(SelfLocal),
    !,
    send(Pid, Message).
send(Pid, Message) :-
    hook_send(Pid, Message),
    !.
send(thread(Tid), Message) :-
    !,
    thread_send_message(Tid, !(Message)).
send(Pid, Message) :-
    send_local(Pid, user, Message).

send_local(Pid, Type, Message) :-
    start,
    next_dispatch_queue(Queue),
    debug(dispatch(send), 'Sending ~p ! ~p', [Pid, Message]),
    thread_send_message(Queue, event(Pid, Type, Message)).

%!  register(+Alias, +Pid) is det.
%!  unregister(?Alias) is det.
%
%   Register the given Pid under the alias Alias.

register(Alias, Pid) :-
    must_be(atom, Alias),
    self_local(Self),
    asserta(registered(Alias, Self, Pid)).

unregister(Alias) :-
    self_local(Self),
    retractall(registered(Alias, Self, _)).

%!  flush
%
%   Print all pending messages

flush :-
    thread_self(Me),
    thread_get_message(Me, !(X), [timeout(0)]),
    !,
    print_message(informational, actor(received(X))),
    flush.
flush.

		 /*******************************
		 *             DEBUG		*
		 *******************************/

dump_backtrace(Id, Depth) :-
    thread_property(E, id(Id)), !,
    engine_post(E, '$backtrace'(Depth), _).

dump_queue(Id, Queue) :-
    thread_property(E, id(Id)), !,
    engine_post(E, '$queue', Queue).

user:portray(Engine) :-
    is_engine(Engine),
    registered(Alias, _, Engine),
    writeq(Alias).

		 /*******************************
		 *            MESSAGES		*
		 *******************************/

:- multifile
    prolog:message//1.

prolog:message(actor(Message)) -->
    message(Message).

message(received(X)) -->
    [ 'Got ~p'-[X] ].
message(delivery_failed(Pid, Message, E)) -->
    [ 'Delivery to ~p of ~p failed:'-[Pid, Message], nl ],
    '$messages':translate_message(E).
