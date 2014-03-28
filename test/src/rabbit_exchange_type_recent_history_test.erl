-module(rabbit_exchange_type_recent_history_test).

-export([test/0]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").
-include("rabbit_recent_history.hrl").

test() ->
    ok = eunit:test(tests(?MODULE, 60), [verbose]).

default_length_test() ->
    Qs = qs(),
    test0(fun () ->
                  #'basic.publish'{exchange = <<"e">>}
          end,
          fun() ->
                  #amqp_msg{props = #'P_basic'{}, payload = <<>>}
          end, [], Qs, 100, length(Qs) * ?KEEP_NB).

length_argument_test() ->
    Qs = qs(),
    test0(fun () ->
                  #'basic.publish'{exchange = <<"e">>}
          end,
          fun() ->
                  #amqp_msg{props = #'P_basic'{}, payload = <<>>}
          end, [{<<"x-recent-history-length">>, long, 30}], Qs, 100, length(Qs) * 30).

wrong_argument_type_test() ->
    {ok, Conn} = amqp_connection:start(#amqp_params_network{}),
    {ok, Chan} = amqp_connection:open_channel(Conn),
    DeclareArgs = [{<<"x-recent-history-length">>, long, -30}],
    process_flag(trap_exit, true),
    ?assertExit(_, amqp_channel:call(Chan,
                          #'exchange.declare' {
                            exchange = <<"e">>,
                            type = <<"x-recent-history">>,
                            auto_delete = true,
                            arguments = DeclareArgs
                            })),
    ok.

no_store_test() ->
    Qs = qs(),
    test0(fun () ->
                  #'basic.publish'{exchange = <<"e">>}
          end,
          fun() ->
                  H = [{<<"x-recent-history-no-store">>, bool, true}],
                  #amqp_msg{props = #'P_basic'{headers = H}, payload = <<>>}
          end, [], Qs, 100, 0).

test0(MakeMethod, MakeMsg, DeclareArgs, Queues, MsgCount, ExpectedCount) ->
    {ok, Conn} = amqp_connection:start(#amqp_params_network{}),
    {ok, Chan} = amqp_connection:open_channel(Conn),
    #'exchange.declare_ok'{} =
        amqp_channel:call(Chan,
                          #'exchange.declare' {
                            exchange = <<"e">>,
                            type = <<"x-recent-history">>,
                            auto_delete = true,
                            arguments = DeclareArgs
                           }),

    #'tx.select_ok'{} = amqp_channel:call(Chan, #'tx.select'{}),
    [amqp_channel:call(Chan,
                       MakeMethod(),
                       MakeMsg()) || _ <- lists:duplicate(MsgCount, const)],
    amqp_channel:call(Chan, #'tx.commit'{}),

    [#'queue.declare_ok'{} =
         amqp_channel:call(Chan, #'queue.declare' {
                             queue = Q, exclusive = true }) || Q <- Queues],

    [#'queue.bind_ok'{} =
         amqp_channel:call(Chan, #'queue.bind' { queue = Q,
                                                 exchange = <<"e">>,
                                                 routing_key = <<"">>})
     || Q <- Queues],

    Counts =
        [begin
            #'queue.declare_ok'{message_count = M} =
                 amqp_channel:call(Chan, #'queue.declare' {queue     = Q,
                                                           exclusive = true }),
             M
         end || Q <- Queues],


    ?assertEqual(ExpectedCount, lists:sum(Counts)),

    amqp_channel:call(Chan, #'exchange.delete' { exchange = <<"e">> }),
    [amqp_channel:call(Chan, #'queue.delete' { queue = Q }) || Q <- Queues],
    amqp_channel:close(Chan),
    amqp_connection:close(Conn),
    ok.

qs() ->
    [<<"q0">>, <<"q1">>, <<"q2">>, <<"q3">>].

tests(Module, Timeout) ->
    {foreach, fun() -> ok end,
     [{timeout, Timeout, fun Module:F/0} ||
         {F, _Arity} <- proplists:get_value(exports, Module:module_info()),
         string:right(atom_to_list(F), 5) =:= "_test"]}.
