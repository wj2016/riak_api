-module(pb_service_test).
-compile([export_all]).
-include_lib("eunit/include/eunit.hrl").

%% ===================================================================
%% Implement a dumb PB service
%% ===================================================================
-behaviour(riak_api_pb_service).
-export([init/0,
         decode/2,
         encode/1,
         process/2,
         process_stream/3]).

-define(MSGMIN, 99).
-define(MSGMAX, 109).

init() ->
    undefined.
decode(99, _) ->
    {ok, bigreq};
decode(101, <<>>) ->
    {ok, dummyreq};
decode(103, <<>>) ->
    {ok, badresponse};
decode(106, <<>>) ->
    {ok, internalerror};
decode(107, <<>>) ->
    {ok, stream};
decode(110, _) ->
    {ok, dummyreq};
decode(111, _) ->
    {ok, stream_multi};
decode(_,_) ->
    {error, unknown_message}.

encode(foo) ->
    {ok, <<108,$f,$o,$o>>};
encode(bar) ->
    {ok, <<109,$b,$a,$r>>};
encode(ok) ->
    {ok, <<102,$o,$k>>};
encode(_) ->
    error.

process(bigreq, State) ->
    {reply, foo, State};
process(stream, State) ->
    Server = self(),
    Ref = make_ref(),
    spawn_link(fun() ->
                       Server ! {Ref, foo},
                       Server ! {Ref, foo},
                       Server ! {Ref, bar},
                       Server ! {Ref, done}
               end),
    {reply, {stream, Ref}, State};
process(stream_multi, State) ->
    Server = self(),
    Ref = make_ref(),
    spawn_link(fun() ->
                       Server ! {Ref, multi},
                       Server ! {Ref, multi_done}
               end),
    {reply, {stream, Ref}, State};
process(internalerror, State) ->
    {error, "BOOM", State};
process(badresponse, State) ->
    {reply, badresponse, State};
process(dummyreq, State) ->
    {reply, ok, State}.

process_stream({Ref,multi_done}, Ref, State) ->
    {done, [foo, bar], State};
process_stream({Ref,done}, Ref, State) ->
    {done, State};
process_stream({Ref, multi}, Ref, State) ->
    {reply, [foo, foo], State};
process_stream({Ref,Msg}, Ref, State) ->
    {reply, Msg, State};
process_stream(_, _, State) ->
    {ignore, State}.


%% ===================================================================
%% Eunit tests
%% ===================================================================
setup() ->
    Deps = resolve_deps(riak_api), %% Implicitly loads apps

    application:set_env(sasl, sasl_error_logger, {file, "pb_service_test_sasl.log"}),
    error_logger:tty(false),
    error_logger:logfile({open, "pb_service_test.log"}),

    application:set_env(lager, handlers, [{lager_file_backend, [{"pb_service_test.log", debug, 10485760, "$D0", 5}]}]),
    application:set_env(lager, error_logger_redirect, true),

    application:set_env(riak_core, handoff_port, 0),

    OldListeners = app_helper:get_env(riak_api, pb, [{"127.0.0.1", 8087}]),
    application:set_env(riak_api, pb, [{"127.0.0.1", 32767}]),

    [ application:start(A) || A <- Deps ],
    riak_core:wait_for_application(riak_api),
    wait_for_port(),
    riak_api_pb_service:register(?MODULE, ?MSGMIN, ?MSGMAX),
    riak_api_pb_service:register(?MODULE, 111),
    {OldListeners, Deps}.

cleanup({L, Deps}) ->
    [ application:stop(A) || A <- lists:reverse(Deps), not is_otp_base_app(A) ],
    wait_for_application_shutdown(riak_api),
    application:set_env(riak_api, pb, L),
    ok.

request_multi(Payloads) when is_list(Payloads) ->
    %% Does raw output framing so we can create incoming buffers that
    %% contain two or more messages.
    Connection = new_connection([]),
    ?assertMatch({ok, _}, Connection),
    {ok, Socket} = Connection,
    Out = [ begin
          MsgSize = iolist_size(Msg) + 1,
          [<<MsgSize:32/unsigned-big, MsgCode:8>>, Msg]
      end || {MsgCode, Msg} <- Payloads ],
    ?assertEqual(ok, gen_tcp:send(Socket, Out)),
    ?assertEqual(ok, inet:setopts(Socket, [{packet,4},{header,1}])),
    [ begin
          Result = gen_tcp:recv(Socket, 0),
          ?assertMatch({ok, _}, Result),
          element(2, Result)
      end || _ <- lists:seq(1, length(Payloads)) ].

request(Code, Payload) when is_binary(Payload), is_integer(Code) ->
    Connection = new_connection(),
    ?assertMatch({ok, _}, Connection),
    {ok, Socket} = Connection,
    request(Code, Payload, Socket).

request(Code, Payload, Socket) when is_binary(Payload), is_integer(Code) ->
    ?assertEqual(ok, gen_tcp:send(Socket, <<Code:8, Payload/binary>>)),
    Result = gen_tcp:recv(Socket, 0),
    ?assertMatch({ok, _}, Result),
    {ok, Response} = Result,
    Response.

request_stream(Code, Payload, DonePredicate) when is_binary(Payload),
                                                  is_integer(Code),
                                                  is_function(DonePredicate) ->
    Connection = new_connection(),
    ?assertMatch({ok, _}, Connection),
    {ok, Socket} = Connection,
    ?assertEqual(ok, gen_tcp:send(Socket, <<Code:8, Payload/binary>>)),
    stream_loop([], gen_tcp:recv(Socket, 0), Socket, DonePredicate).

stream_loop(Acc0, {ok, [Code|Bin]=Packet}, Socket, Predicate) ->
    Acc = [{Code, Bin}|Acc0],
    case Predicate(Packet) of
        true ->
            lists:reverse(Acc);
        false ->
            stream_loop(Acc, gen_tcp:recv(Socket, 0), Socket, Predicate)
    end.

new_connection() ->
    new_connection([{packet,4}, {header, 1}]).

new_connection(Options) ->
    {Host, Port} = hd(app_helper:get_env(riak_api, pb)),
    gen_tcp:connect(Host, Port, [binary, {active, false},{nodelay, true}|Options]).

simple_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [
      %% Happy path, sync operation
      ?_assertEqual([102|<<"ok">>], request(101, <<>>)),
      %% Happy path, streaming operation
      ?_assertEqual([{108, <<"foo">>},{108, <<"foo">>},{109,<<"bar">>}],
                    request_stream(107, <<>>, fun([Code|_]) -> Code == 109 end)),
      %% Happy path, multi-message streaming
      ?_assertEqual([{108, <<"foo">>},{108, <<"foo">>},{108, <<"foo">>}, {109,<<"bar">>}],
                    request_stream(111, <<>>, fun([Code|_]) -> Code == 109 end)),
      %% Unknown request message code
      ?_assertMatch([0|Bin] when is_binary(Bin), request(105, <<>>)),
      %% Undecodable request message code
      ?_assertMatch([0|Bin] when is_binary(Bin), request(102, <<>>)),
      %% Unencodable response message
      ?_assertMatch([0|Bin] when is_binary(Bin), request(103, <<>>)),
      %% Internal service error
      ?_assertMatch([0|Bin] when is_binary(Bin), request(106, <<>>)),
      %% Send a message that spans multiple TCP packets
      ?_assertMatch([108|<<"foo">>], request(99, binary:copy(<<"BIGDATA">>, 1024))),
      %% Send a payload with more than one message in it
      ?_assertMatch([[102|<<"ok">>],[102|<<"ok">>]],
                    request_multi([{101, <<>>}, {101, <<>>}]))
     ]}.

late_registration_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     ?_test(begin
                %% First we check that the unregistered message code
                %% returns an error to the client.
                ?assertMatch([0|Bin] when is_binary(Bin), request(110, <<>>)),
                %% Now we make a new connection
                {ok, Socket} = new_connection(),
                %% And with the connection open, register the message code late.
                riak_api_pb_service:register(?MODULE, 110),
                %% Now request the message and we should get success.
                ?assertEqual([102|<<"ok">>], request(110, <<>>, Socket))
            end)
    }.

deregister_during_shutdown_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     ?_test(begin
                %% Shutdown riak_api
                application:stop(riak_api),
                %% Make sure deregistration doesn't fail
                ?assertEqual(ok, riak_api_pb_service:deregister(?MODULE, ?MSGMIN, ?MSGMAX))
            end)
     }.

wait_for_port() ->
    wait_for_port(10000).

wait_for_port(Timeout) when is_integer(Timeout) ->
    lager:debug("Waiting for PB Port within timeout ~p", [Timeout]),
    TRef = erlang:send_after(Timeout, self(), timeout),
    wait_for_port(TRef);
wait_for_port(TRef) ->
    Me = self(),
    erlang:spawn(fun() ->
                         case new_connection() of
                             {ok, Socket} ->
                                 gen_tcp:close(Socket),
                                 Me ! connected;
                             {error, Reason} ->
                                 Me ! {error, Reason}
                         end
                 end),
    receive
        timeout ->
            lager:error("PB port did not come up within timeout"),
            {error, timeout};
        {error, Reason} ->
            lager:debug("Waiting for PB port failed: ~p", [Reason]),
            wait_for_port(TRef);
        connected ->
            erlang:cancel_timer(TRef),
            lager:debug("PB port is up"),
            ok
    end.

wait_for_application_shutdown(App) ->
    case lists:keymember(App, 1, application:which_applications()) of
        true ->
            timer:sleep(250),
            wait_for_application_shutdown(App);
        false ->
            ok
    end.

%% The following three functions build a list of dependent
%% applications. They will not handle circular or mutually-dependent
%% applications.
dep_apps(App) ->
    application:load(App),
    {ok, Apps} = application:get_key(App, applications),
    Apps.

all_deps(App, Deps) ->
    [[ all_deps(Dep, [App|Deps]) || Dep <- dep_apps(App),
                                    not lists:member(Dep, Deps)], App].

resolve_deps(App) ->
    DepList = all_deps(App, []),
    {AppOrder, _} = lists:foldl(fun(A,{List,Set}) ->
                                        case sets:is_element(A, Set) of
                                            true ->
                                                {List, Set};
                                            false ->
                                                {List ++ [A], sets:add_element(A, Set)}
                                        end
                                end,
                                {[], sets:new()},
                                lists:flatten(DepList)),
    AppOrder.

is_otp_base_app(kernel) -> true;
is_otp_base_app(stdlib) -> true;
is_otp_base_app(_) -> false.
