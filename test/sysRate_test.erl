
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
    preamble(),
    ResFalse = sysRate:is_limiter_running(lim1),
    ?assertEqual(false, ResFalse),
    sysRate:define(lim1, []),
    ResTrue = sysRate:is_limiter_running(lim1),
    ?assertEqual(true, ResTrue),
    postamble().

simple_rate_test() ->
    preamble(),
    ?assertEqual(false, sysRate:is_limiter_running(lim1)),
    sysRate:define(lim1, [{rate, 1}, manual_tick]),
    Res = do_n_requests(lim1, 5),
    Expected = [true, false, false, false, false],
    ?assertEqual(Expected, Res),
    postamble().

rate_tick_once_test() ->
    preamble(),
    ?assertEqual(false, sysRate:is_limiter_running(lim1)),
    sysRate:define(lim1, [{rate, 1}, manual_tick, {period, 500}]),
    Res1 = do_n_requests(lim1, 5),
    Expected = [true, false, false, false, false],
    ?assertEqual(Expected, Res1),
    sysRate:tick(lim1),
    Res2 = do_n_requests(lim1, 5),
    ?assertEqual(Expected, Res2),
    postamble().

rate_tick_uneven_test() ->
    preamble(),
    ?assertEqual(false, sysRate:is_limiter_running(lim1)),
    sysRate:define(lim1, [{rate, 1}, manual_tick, {period, 300}]),
    ExpectedOne = [true, false, false],
    ExpectedNone = [false, false, false],
    
    Res1 = do_n_requests(lim1, 3),
    ?assertEqual(ExpectedOne, Res1),
    sysRate:tick(lim1),
    Res2 = do_n_requests(lim1, 3),
    ?assertEqual(ExpectedNone, Res2),
    sysRate:tick(lim1),
    Res3 = do_n_requests(lim1, 3),
    ?assertEqual(ExpectedOne, Res3),
    sysRate:tick(lim1),
    Res4 = do_n_requests(lim1, 3),
    ?assertEqual(ExpectedNone, Res4),
    sysRate:tick(lim1),
    Res5 = do_n_requests(lim1, 3),
    ?assertEqual(ExpectedNone, Res5),
    sysRate:tick(lim1),
    Res6 = do_n_requests(lim1, 3),
    ?assertEqual(ExpectedOne, Res6),

    postamble().

check_many_rates_test_() ->
    {foreach,
     fun() -> preamble() end,
     fun(_) -> postamble() end,
     [
      {"rate=10, period=50",
       fun() -> run_bucket(10, 50) end},
      {"rate=10, period=73",
       fun() -> run_bucket(10, 73) end},
      {"rate=10, period=100",
       fun() -> run_bucket(10, 100) end},
      {"rate=10, period=200",
       fun() -> run_bucket(10, 200) end},
      {"rate=10, period=300",
       fun() -> run_bucket(10, 300) end},
      {"rate=10, period=130",
       fun() -> run_bucket(10, 130) end},
      {"rate=10, period=170",
       fun() -> run_bucket(10, 470) end},
      {"dummy", fun() -> ok end} ]}.

run_bucket(Rate, Period) ->
    sysRate:define(lim1, [{rate, Rate}, manual_tick, {period, Period}]),
    Revoultions = 20*(1+round(1000 / Period)),
    %% The +1 comes from the burst limit
    TotTime = ((Revoultions)*Period/1000),
    Ok = ok_count(tl(do_run_bucket(lim1, Revoultions, Rate))),
    ActualRate = one_decimal(Ok/(TotTime)),
    %% io:format("Revs: ~p, tot time: ~p, tot: ~p, rate: ~p~n", 
    %%           [Revoultions, TotTime, Ok, ActualRate]),
    ?assertEqual(10.0, ActualRate).

one_decimal(X) ->
    round(X*10) / 10.
    
ok_count(L) ->
    length(lists:filter(fun(X) -> X end, flat(L))).

do_run_bucket(Lim, 0, Rate) ->
    Res = do_n_requests(Lim, 2*Rate),
    [Res];
do_run_bucket(Lim, Revs, Rate) ->
    Res = do_n_requests(Lim, 2*Rate),
    sysRate:tick(Lim),
    [Res | do_run_bucket(Lim, Revs-1, Rate)].

do_n_requests(LimiterName, N) ->
    [sysRate:is_request_allowed(LimiterName) || _ <- lists:seq(1, N)].

preamble() ->
    sysRate:start_link().

postamble() ->
    sysRate:stop().

flat(L) -> lists:flatten(L).
    

