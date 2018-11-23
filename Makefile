clean:

test: clean
	rebar3 ct && rebar3 eunit
