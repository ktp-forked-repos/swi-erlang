/*  Part of SWI-Prolog

    Author:        Torbjörn Lager and Jan Wielemaker
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

:- module(rpc,        
          [ rpc/2,                      % +URI, :Query
            rpc/3,                      % +URI, :Query, +Options
            promise/3,                  % +URI, :Query, -Reference
            promise/4,                  % +URI, :Query, -Reference, +Options
            yield/2                     % +Reference, ?Message
          ]).

:- use_module(library(http/http_open)).
:- use_module(library(debug)).

:- use_module(pengines).
:- use_module(dispatch).



         /*******************************
         *       Synchronous RPC        *
         *******************************/


%!  rpc(+URI, :Query) is nondet.
%!  rpc(+URI, :Query, +Options) is nondet.
%
%   Make synchronous call to node URI with Query. Options:
%
%     - transport(+Transport)
%       Transport must be either `http' (default) or `websocket'.
%       Note that `http' cannot be combined with the `src_*'
%       options.
%     - limit(+Integer)
%       Limit the number of network roundtrips when dealing with 
%       queries with more than one solution.

rpc(URI, Query) :-
    rpc(URI, Query, []).
    
rpc(URI, Query, Options) :-
    select_option(transport(Transport), Options, RestOptions, http),
    (   Transport == http
    ->  rpc_http(URI, Query, RestOptions)
    ;   memberchk(Transport, [websocket, ws])
    ->  rpc_ws(URI, Query, RestOptions)
    ).


%!  rpc_http(+URI, :Query, +Options) is nondet.
%
%   @tbd: Use template option with only vars for efficiency
    
rpc_http(URI, Query, Options) :-
    option(limit(Limit), Options, 1),
    rpc_http(URI, Query, 0, Limit).
    
rpc_http(URI, Query, Offset, Limit) :-
    parse_url(URI, Parts),
    format(atom(QueryAtom), "(~p)", [Query]),
    rpc_http(Query, Offset, Limit, QueryAtom, Parts).
    
rpc_http(Query, Offset, Limit, QueryAtom, Parts) :-    
    parse_url(ExpandedURI, [ path('/api/pengine_ask'),
                             search([ query=QueryAtom,
                                      offset=Offset,
                                      limit=Limit
                                    ])
                           | Parts]), 
    setup_call_cleanup(
        http_open(ExpandedURI, Stream, []),
        read(Stream, Answer), 
        close(Stream)),
    wait_answer(Answer, Query, Offset, Limit, QueryAtom, Parts).

wait_answer(error(anonymous, Error), _Query, _Offset, _Limit, _QueryAtom, _Parts):-
    throw(Error).
wait_answer(failure(anonymous), _Query, _Offset, _Limit, _QueryAtom, _Parts):-
    fail.
wait_answer(success(anonymous, Solutions, false), Query, _Offset, _Limit, _QueryAtom, _Parts) :- 
    !,
    member(Query, Solutions).
wait_answer(success(anonymous, Solutions, true), Query, Offset0, Limit, QueryAtom, Parts) :-
    (   member(Query, Solutions)
    ;   Offset is Offset0 + Limit,
        rpc_http(Query, Offset, Limit, QueryAtom, Parts)
    ).


%!  rpc_ws(+URI, :Query, +Options) is nondet.
%

rpc_ws(URI, Query, Options) :-
    atom_concat(URI, '/erlang', WsURI),
    pengine_spawn(Pid, [
         node(WsURI),
         exit(true),
         monitor(false)
       | Options
    ]),
    pengine_ask(Pid, Query, Options),
    wait_answer(Query, Pid).


% TODO: Investigate why _Pid \= Pid. 
% Hypothesis: Because the messages contains an incomplete (non-ground) Pid
% and since receive uses subsumption rather than unification.
% So how do we get the right Pid?

wait_answer(Query, Pid) :-
    receive({
        failure(_) -> fail;            
        error(_, Exception) -> 
            throw(Exception);                  
        success(_Pid, Solutions, true) -> 
            % writeln(Pid),
            % writeln(_Pid),
            (   member(Query, Solutions)
            ;   pengine_next(Pid), 
                wait_answer(Query, Pid)
            );
        success(_, Solutions, false) -> 
            member(Query, Solutions)
    }).

