PROJECT = gen_batch_server
PROJECT_DESCRIPTION = Generic batching server
PROJECT_VERSION = 0.5.0-pre.1

define PROJECT_ENV
[
]
endef

TEST_DEPS = proper meck eunit_formatters

PLT_APPS += eunit meck proper syntax_tools erts kernel stdlib common_test

DIALYZER_OPTS += --src -r test
EUNIT_OPTS = no_tty, {report, {eunit_progress, [colored, profile]}}

include erlang.mk

shell: app
