/* server2 doesn't not work due to error:

exception(error(existence_error(procedure,web_prolog:server1/1),
context(system: <meta-call> / 1,_G149)))

*/

start1(Pid) :-
	self(S),
	spawn(server1(S), Pid, [
		src_predicates([server1/1])
	]).

server1(Pid) :-
    repeat,
    receive({
        ping ->
            send(Pid, pong),
            fail
    }). 


start2(Pid) :-
	self(S),
	spawn(server2(S), Pid, [
		src_predicates([server2/1])
	]).
    
server2(Pid) :-
    receive({
        ping ->
            send(Pid, pong),
            server2(Pid)
    }).
    

          
/** Examples

start1(Pid), send(Pid, ping)
send($Pid, ping)
flush

start2(Pid), send(Pid, ping)
send($Pid, ping)
flush
    
*/