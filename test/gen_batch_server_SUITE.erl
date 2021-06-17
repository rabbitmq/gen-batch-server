%% Copyright (c) 2018-Present Pivotal Software, Inc. All Rights Reserved.
-module(gen_batch_server_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-export([
         ]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% Common Test callbacks
%%%===================================================================

all() ->
    [
     {group, tests}
    ].


all_tests() ->
    [
     start_link_calls_init,
     simple_start_link_calls_init,
     handle_continue,
     cast_calls_handle_batch,
     info_calls_handle_batch,
     cast_many,
     cast_batch,
     ordering,
     ordering_reversed,
     call_calls_handle_batch,
     returning_stop_calls_terminate,
     terminate_is_optional,
     sys_get_status_calls_format_status,
     format_status_is_optional,
     max_batch_size,
     stop_calls_terminate,
     process_hibernates
    ].

groups() ->
    [
     {tests, [], all_tests()}
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(TestCase, Config) ->

    [{mod, TestCase} | Config].

end_per_testcase(_TestCase, _Config) ->
    meck:unload(),
    ok.

%%%===================================================================
%%% Test cases
%%%===================================================================

start_link_calls_init(Config) ->
    Mod = ?config(mod, Config),
    meck:new(Mod, [non_strict]),
    meck:expect(Mod, init, fun([{some_arg, argh}]) ->
                                   {ok, #{}}
                           end),
    Args = [{some_arg, argh}],
    {ok, Pid} = gen_batch_server:start_link({local, Mod}, Mod, Args),
    ?assertEqual(true, meck:called(Mod, init, '_', Pid)),
    {ok, Pid2} = gen_batch_server:start_link(Mod, Args),
    ?assertEqual(true, meck:called(Mod, init, '_', Pid2)),
    {ok, Pid3} = gen_batch_server:start_link(undefined, Mod, Args),
    ?assertEqual(true, meck:called(Mod, init, '_', Pid3)),
    Opts = [{reversed_batch, true}],
    {ok, Pid4} = gen_batch_server:start_link(undefined, Mod, Args, Opts),
    ?assertEqual(true, meck:called(Mod, init, '_', Pid4)),
    ?assert(meck:validate(Mod)),
    gen_batch_server:stop(Pid),
    gen_batch_server:stop(Pid2),
    gen_batch_server:stop(Pid3),
    gen_batch_server:stop(Pid4),
    ok.

simple_start_link_calls_init(Config) ->
    Mod = ?config(mod, Config),
    meck:new(Mod, [non_strict]),
    meck:expect(Mod, init, fun([{some_arg, argh}]) ->
                                   {ok, #{}}
                           end),
    Args = [{some_arg, argh}],
    {ok, Pid} = gen_batch_server:start_link(Mod, Args),
    %% having to wildcard the args as they don't seem to
    %% validate correctly
    ?assertEqual(true, meck:called(Mod, init, '_', Pid)),
    ?assert(meck:validate(Mod)),
    ok.

handle_continue(Config) ->
    Self = self(),
    Mod = ?config(mod, Config),
    meck:new(Mod, [non_strict]),
    meck:expect(Mod, init, fun([{some_arg, argh}]) ->
                                   {ok, #{}, {continue, post_init}}
                           end),
    meck:expect(Mod, handle_continue, fun(Cont, #{}) ->
                                              Self ! {continue_called, Cont},
                                              {ok, #{}}
                                      end),
    meck:expect(Mod, handle_batch, fun(_Batch, #{}) ->
                                           {ok, #{}, {continue, batch}}
                                   end),
    Args = [{some_arg, argh}],
    {ok, Pid} = gen_batch_server:start_link(Mod, Args),
    %% having to wildcard the args as they don't seem to
    %% validate correctly
    ?assertEqual(true, meck:called(Mod, init, '_', Pid)),
    ?assertEqual(true, meck:called(Mod, handle_continue, '_', Pid)),
    receive
        {continue_called, post_init} -> ok
    after 2000 ->
              exit(continue_timeout)
    end,
    ok  = gen_batch_server:cast(Pid, msg),
    receive
        {continue_called, batch} -> ok
    after 2000 ->
              exit(continue_timeout_2)
    end,
    meck:expect(Mod, handle_batch, fun(_Batch, #{}) ->
                                           {ok, [garbage_collect], #{}, {continue, batch}}
                                   end),
    ok  = gen_batch_server:cast(Pid, msg),
    receive
        {continue_called, batch} -> ok
    after 2000 ->
              exit(continue_timeout_3)
    end,
    ?assert(meck:validate(Mod)),
    ok.

cast_calls_handle_batch(Config) ->
    Mod = ?config(mod, Config),
    meck:new(Mod, [non_strict]),
    meck:expect(Mod, init, fun(Init) -> {ok, Init} end),
    Args = #{},
    {ok, Pid} = gen_batch_server:start_link({local, Mod}, Mod, Args, []),
    Msg = {put, k, v},
    Self = self(),
    meck:expect(Mod, handle_batch,
                fun([{cast, {put, k, v}}], State) ->
                        Self ! continue,
                        {ok, [garbage_collect], maps:put(k, v, State)}
                end),
    ok = gen_batch_server:cast(Pid, Msg),
    receive continue -> ok after 2000 -> exit(timeout) end,
    ?assertEqual(true, meck:called(Mod, handle_batch, '_', Pid)),
    {ok, Pid1} = gen_batch_server:start_link({global, Mod}, Mod, Args, []),
    ok  = gen_batch_server:cast({global, Mod}, Msg),
    receive continue -> ok after 2000 -> exit(timeout) end,
    ?assertEqual(true, meck:called(Mod, handle_batch, '_', Pid1)),
    {ok, Pid2} = gen_batch_server:start_link({via, global, test_via_cast}, Mod, Args, []),
    ok  = gen_batch_server:cast({via, global, test_via_cast}, Msg),
    receive continue -> ok after 2000 -> exit(timeout) end,
    ?assertEqual(true, meck:called(Mod, handle_batch, '_', Pid2)),
    ?assert(meck:validate(Mod)),
    ok.

info_calls_handle_batch(Config) ->
    Mod = ?config(mod, Config),
    meck:new(Mod, [non_strict]),
    meck:expect(Mod, init, fun(Init) -> {ok, Init} end),
    Args = #{},
    {ok, Pid} = gen_batch_server:start_link({local, Mod}, Mod, Args, []),
    Msg = {put, k, v},
    Self = self(),
    meck:expect(Mod, handle_batch,
                fun([{info, {put, k, v}}], State) ->
                        Self ! continue,
                        {ok, [], maps:put(k, v, State)}
                end),
    Pid ! Msg,
    receive continue -> ok after 2000 -> exit(timeout) end,
    ?assertEqual(true, meck:called(Mod, handle_batch, '_', Pid)),
    ?assert(meck:validate(Mod)),
    ok.

process_hibernates(Config) ->
    Mod = ?config(mod, Config),
    meck:new(Mod, [non_strict]),
    meck:expect(Mod, init, fun(Init) -> {ok, Init} end),
    Args = #{},
    {ok, Pid} = gen_batch_server:start_link({local, Mod}, Mod, Args,
                                            [{hibernate_after, 10}]),
    %% sleep longer than hibernation wait
    timer:sleep(20),
    ?assertEqual({current_function, {erlang, hibernate, 3}},
                 erlang:process_info(Pid, current_function)),
    Msg = {put, k, v},
    Self = self(),
    meck:expect(Mod, handle_batch,
                fun([{info, {put, k, v}}], State) ->
                        Self ! continue,
                        {ok, [], maps:put(k, v, State)}
                end),
    Pid ! Msg,
    receive continue -> ok after 2000 -> exit(timeout) end,
    ?assertEqual(true, meck:called(Mod, handle_batch, '_', Pid)),
    ?assert(meck:validate(Mod)),
    timer:sleep(20),
    ?assertEqual({current_function, {erlang, hibernate, 3}},
                 erlang:process_info(Pid, current_function)),
    ok.

cast_many(Config) ->
    Mod = ?config(mod, Config),
    meck:new(Mod, [non_strict]),
    meck:expect(Mod, init, fun(Init) -> {ok, Init} end),
    Args = #{},
    {ok, Pid} = gen_batch_server:start_link({local, Mod}, Mod, Args, []),
    Self = self(),
    meck:expect(Mod, handle_batch,
                fun(Ops, State) ->
                        {cast, {put, K, V}} = lists:last(Ops),
                        Self ! {done, K, V},
                        {ok, [], maps:put(K, V, State)}
                end),
    Num = 20000,
    [gen_batch_server:cast(Pid, {put, I, I}) || I <- lists:seq(1, Num)],
    receive {done, Num, Num} ->
                ok
    after 5000 ->
              exit(timeout)
    end,
    ?assert(meck:validate(Mod)),
    ok.

cast_batch(Config) ->
    Mod = ?config(mod, Config),
    meck:new(Mod, [non_strict]),
    meck:expect(Mod, init, fun(Init) -> {ok, Init} end),
    Args = #{},
    {ok, Pid} = gen_batch_server:start_link({local, Mod}, Mod, Args, []),
    Self = self(),
    meck:expect(Mod, handle_batch,
                fun(Ops, State) ->
                        {cast, {put, K, V}} = lists:last(Ops),
                        Self ! {done, K, V},
                        {ok, [], maps:put(K, V, State)}
                end),
    Num = 20000,
    gen_batch_server:cast_batch(Pid, [{put, I, I} || I <- lists:seq(1, Num)]),
    receive {done, Num, Num} ->
                ok
    after 5000 ->
              exit(timeout)
    end,
    ?assert(meck:validate(Mod)),
    ok.

ordering(Config) ->
    test_ordering(Config, false).

ordering_reversed(Config) ->
    test_ordering(Config, true).

test_ordering(Config, Reverse) ->
    Mod = ?config(mod, Config),
    meck:new(Mod, [non_strict]),
    meck:expect(Mod, init, fun(Init) -> {ok, Init} end),
    Args = #{},
    Opts = [{reversed_batch, Reverse}],
    {ok, Pid} = gen_batch_server:start_link({local, Mod}, Mod, Args, Opts),
    Self = self(),
    ExpectedOps = [{cast,1}, {cast,2}, {cast,3}, {cast,4}, {cast,5}],
    Expected = case Reverse of
                   false ->
                       ExpectedOps;
                   true ->
                       lists:reverse(ExpectedOps)
               end,

    meck:expect(Mod, handle_batch,
                fun([{cast, block}], State) ->
                        timer:sleep(100),
                        {ok, State};
                   (Ops, State) ->
                        case Ops of
                            Expected ->
                                Self ! in_order;
                            _ ->
                                Self ! {out_of_order, Ops}
                        end,
                        {ok, State}
                end),
    gen_batch_server:cast(Pid, block),
    timer:sleep(10),
    gen_batch_server:cast(Pid, 1),
    gen_batch_server:cast_batch(Pid, [I || I <- lists:seq(2, 4)]),
    gen_batch_server:cast(Pid, 5),

    receive in_order ->
                ok;
            {out_of_order, Ops} ->
                ct:pal("out of order ops ~w", [Ops]),
                exit({outof_order_assertion, Ops})
    after 5000 ->
              exit(timeout)
    end,
    ?assert(meck:validate(Mod)),
    ok.

call_calls_handle_batch(Config) ->
    Mod = ?config(mod, Config),
    meck:new(Mod, [non_strict]),
    meck:expect(Mod, init, fun(Init) -> {ok, Init} end),
    Args = #{},
    {ok, Pid} = gen_batch_server:start_link({local, Mod}, Mod, Args, []),
    Msg = {put, k, v},
    meck:expect(Mod, handle_batch,
                fun([{call, From, {put, k, v}}], State) ->
                        {ok, [{reply, From, {ok, k}}, garbage_collect],
                         maps:put(k, v, State)}
                end),
    {ok, k}  = gen_batch_server:call(Pid, Msg),
    ?assertEqual(true, meck:called(Mod, handle_batch, '_', Pid)),
    {ok, Pid1} = gen_batch_server:start_link({global, Mod}, Mod, Args, []),
    {ok, k}  = gen_batch_server:call({global, Mod}, Msg),
    ?assertEqual(true, meck:called(Mod, handle_batch, '_', Pid1)),
    {ok, Pid2} = gen_batch_server:start_link({via, global, test_via_call}, Mod, Args, []),
    {ok, k}  = gen_batch_server:call({via, global, test_via_call}, Msg),
    ?assertEqual(true, meck:called(Mod, handle_batch, '_', Pid2)),
    ?assert(meck:validate(Mod)),
    ok.

returning_stop_calls_terminate(Config) ->
    Mod = ?config(mod, Config),
    %% as we are linked the test process need to also trap exits for this test
    process_flag(trap_exit, true),
    meck:new(Mod, [non_strict]),
    meck:expect(Mod, init, fun(Init) ->
                                   process_flag(trap_exit, true),
                                   {ok, Init}
                           end),
    Args = #{},
    {ok, Pid} = gen_batch_server:start_link({local, Mod}, Mod,
                                            Args, []),
    Msg = {put, k, v},
    meck:expect(Mod, handle_batch,
                fun([{cast, {put, k, v}}], _) ->
                        {stop, because}
                end),
    meck:expect(Mod, terminate, fun(because, S) -> S end),
    ok = gen_batch_server:cast(Pid, Msg),
    %% wait for process exit signal
    receive {'EXIT', Pid, because} -> ok after 2000 -> exit(timeout) end,
    %% sleep a little to allow meck to register results
    timer:sleep(10),
    ?assertEqual(true, meck:called(Mod, terminate, '_')),
    ?assert(meck:validate(Mod)),
    ok.

terminate_is_optional(Config) ->
    Mod = ?config(mod, Config),
    %% as we are linked the test process need to also trap exits for this test
    process_flag(trap_exit, true),
    meck:new(Mod, [non_strict]),
    meck:expect(Mod, init, fun(Init) ->
                                   process_flag(trap_exit, true),
                                   {ok, Init}
                           end),
    Args = #{},
    {ok, Pid} = gen_batch_server:start_link({local, Mod}, Mod,
                                            Args, []),
    Msg = {put, k, v},
    meck:expect(Mod, handle_batch,
                fun([{cast, {put, k, v}}], _) ->
                        {stop, because}
                end),
    ok = gen_batch_server:cast(Pid, Msg),
    %% wait for process exit signal
    receive {'EXIT', Pid, because} -> ok after 2000 -> exit(timeout) end,
    %% sleep a little to allow meck to register results
    timer:sleep(10),
    ?assertEqual(false, meck:called(Mod, terminate, '_')),
    ?assert(meck:validate(Mod)),
    ok.

sys_get_status_calls_format_status(Config) ->
    Mod = ?config(mod, Config),
    meck:new(Mod, [non_strict]),
    meck:expect(Mod, init, fun(Init) ->
                                   {ok, Init}
                           end),
    meck:expect(Mod, format_status,
                fun(S) ->
                        {format_status, S}
                end),
    {ok, _Pid} = gen_batch_server:start_link({local, Mod}, Mod,
                                             #{}, []),

    {_, _, _, [_, _, _, _, [_, _ ,S]]} = sys:get_status(Mod),
    ?assertEqual({format_status, #{}}, S),

    ?assertEqual(true, meck:called(Mod, format_status, '_')),
    ?assert(meck:validate(Mod)),
    ok.

format_status_is_optional(Config) ->
    Mod = ?config(mod, Config),
    meck:new(Mod, [non_strict]),
    Args = bananas,
    meck:expect(Mod, init, fun(Init) ->
                                   {ok, Init}
                           end),
    {ok, _Pid} = gen_batch_server:start_link({local, Mod}, Mod,
                                             Args, []),

    {_, _, _, [_, _, _, _, [_, _ ,S]]} = sys:get_status(Mod),
    ?assertEqual(Args, S),

    ?assertEqual(false, meck:called(Mod, format_status, '_')),
    ?assert(meck:validate(Mod)),
    ok.

max_batch_size(Config) ->
    Mod = ?config(mod, Config),
    meck:new(Mod, [non_strict]),
    meck:expect(Mod, init, fun(Init) -> {ok, Init} end),
    Args = #{},
    {ok, Pid} = gen_batch_server:start_link({local, Mod}, Mod, Args, [{max_batch_size, 5000}]),
    Self = self(),
    Num = 20000,
    meck:expect(Mod, handle_batch,
                fun(Ops, State) ->
                        {cast, {put, K, V}} = lists:last(Ops),
                        ct:pal("cast_batch: batch size ~b~n", [length(Ops)]),
                        Self ! {last, K, V},
                        case K of
                            Num ->
                                Self ! done;
                            _ ->
                                ok
                        end,
                        {ok, [], maps:put(K, V, State)}
                end),
    [gen_batch_server:cast(Pid, {put, I, I}) || I <- lists:seq(1, Num)],
    [Num | _] = BatchResult = wait_batch(),
    ?assert(BatchResult >= 4),
    ?assert(meck:validate(Mod)),
    ok.

stop_calls_terminate(Config) ->
    Mod = ?config(mod, Config),
    %% as we are linked the test process need to also trap exits for this test
    process_flag(trap_exit, true),
    meck:new(Mod, [non_strict]),
    meck:expect(Mod, init, fun(Init) ->
                                   process_flag(trap_exit, true),
                                   {ok, Init}
                           end),
    Args = #{},
    {ok, Pid} = gen_batch_server:start_link({local, Mod}, Mod,
                                            Args, []),
    meck:expect(Mod, terminate, fun(because, S) -> S end),
    ok = gen_batch_server:stop(Pid, because, infinity),
    %% wait for process exit signal
    receive {'EXIT', Pid, because} -> ok after 2000 -> exit(timeout) end,
    %% sleep a little to allow meck to register results
    timer:sleep(10),
    ?assertEqual(true, meck:called(Mod, terminate, '_')),
    ?assert(meck:validate(Mod)),
    ok.

%% Utility
wait_batch() ->
    wait_batch([]).

wait_batch(Acc) ->
    receive
        {last, Num, Num} ->
            wait_batch([Num | Acc]);
        done ->
            Acc
    after 5000 ->
              exit(timeout)
    end.
