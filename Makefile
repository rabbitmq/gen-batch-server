EPMD ?= $(shell which epmd)
REBAR ?= $(shell which rebar3)

clean:
	$(REBAR) clean

xref:
	@$(REBAR) xref

dialyzer:
	@$(REBAR) dialyzer

test: clean
	@$(EPMD) -daemon
	@$(REBAR) ct --readable=false --sname=batch_test
