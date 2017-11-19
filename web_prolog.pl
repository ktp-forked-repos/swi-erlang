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

:- module(web_prolog,
          [ flush/0,                    % From actors
            spawn/1,                    % :Goal
            spawn/2,                    % :Goal, -Pid
            spawn/3,                    % :Goal, -Pid, +Options
            send/2,                     % +Pid, +Message
            (!)/2,			            % +Pid, +Message
            exit/1,                     % +Reason
            exit/2,                     % +Pid, +Reason
            receive/1,                  % +Clauses
            link/2,                     % +Parent, +Child
            self/1,                     % -Pid
            register/2,                 % +Alias, +Pid
            unregister/1,		        % +Alias
           
            pengine_spawn/1,            % -Pid
            pengine_spawn/2,            % -Pid, +Options
            pengine_ask/2,              % +Pid, +Query
            pengine_ask/3,              % +Pid, +Query, +Options
            pengine_next/1,             % +Pid
            pengine_next/2,             % +Pid, +Options
            pengine_stop/1,             % +Pid                   
            pengine_abort/1,            % +Pid    
            pengine_input/2,            % +Prompt, ?Answer
            pengine_respond/2,          % +Pid, +Answer
            pengine_output/1,           % +Term
            
            rpc/2,                      % +URI, :Query
            rpc/3,                      % +URI, :Query, +Options
            promise/3,                  % +URI, :Query, -Reference
            promise/4,                  % +URI, :Query, -Reference, +Options
            yield/2,                    % +Reference, ?Message

            dump_backtrace/2,           % +Pid, +Depth
            dump_queue/2,               % +Pid, -Queue

            op(1000, xfx, when),
            op(800, xfx, !),

            node/0,              % from node
            node/1
          ]).
:- use_module(library(option)).

:- use_module(actors).
:- use_module(distribution).
:- use_module(node).
:- use_module(isolation).
:- use_module(pengines).
:- use_module(restful_api).
:- use_module(rpc).

:- multifile
    actors:hook_goal/3.

actors:hook_goal(Goal0, isolation:with_source(Goal0, GoalOptions), Options) :-
    \+ option(node(_), Options),
    actor_uuid(Module),
    GoalOptions = [ module(Module)
                  | Options
                  ].

actor_uuid(Module) :-
        uuid(Module, [version(4)]).