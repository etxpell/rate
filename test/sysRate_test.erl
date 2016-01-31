
-module(sysRate_test).
-include_lib("eunit/include/eunit.hrl").
-compile(export_all).





start_stop_test() ->
    Res = sysRate:start_link(),
    ?assertMatch({ok, _}, Res),
    {ok, Pid} = Res,
    ?assertEqual(true, is_pid(Pid)),
    ?assertEqual(true, is_pid(whereis(sysRate))),
    StopRes = sysRate:stop(),
    ?assertEqual(StopRes, ok),
    ?assertEqual(false, is_pid(whereis(sysRate))).


define_test() ->
    pre_amble(),
    ResFalse = sysRate:is_limiter_running(lim1),
    ?assertEqual(false, ResFalse),
    sysRate:define(lim1, []),
    ResTrue = sysRate:is_limiter_running(lim1),
    ?assertEqual(true, ResTrue),
    post_amble().

simple_test() ->
    pre_amble(),
    ?assertEqual(false, sysRate:is_limiter_running(lim1)),
    sysRate:define(lim1, [{rate, 1}, manual_tick]),
    Res = do_n_requests(lim1, 5),
    Expected = [true, false, false, false, false],
    ?assertEqual(Expected, Res),
    post_amble().


do_n_requests(LimiterName, N) ->
    [sysRate:is_request_allowed(LimiterName) || _ <- lists:seq(1, N)].

pre_amble() ->
    sysRate:start_link().

post_amble() ->
    sysRate:stop().

