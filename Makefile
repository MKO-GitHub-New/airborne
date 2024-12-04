PHONY: celery clean devserver eslint pep8
.PHONY: pin_requirements server shell test install static static/js make_locale
.PHONY: download_locale upload_locale magic deploy_actions coveragepy coveragepy_show

PROJECT = airborne
STATIC = static

ENV ?= venv
VENV := $(shell echo $(VIRTUAL_ENV))
VENV_SRC := $(if $(VENV),$(wildcard $(join $(VENV)/,src/)),)

COVERAGE = coverage
HONCHO = honcho
PEP8 = flake8
PIP = pip
PYTHON = python
DRAFTER = drafter --use-line-num --validate

# JS tests settings
AIRBORNE_ROOT = $(STATIC)/airborne
COMMON_JS_PATH = $(AIRBORNE_ROOT)/js
HOTELS_JS_PATH = $(AIRBORNE_ROOT)/hotels/js
VENDORS_JS_PATH = $(AIRBORNE_ROOT)/vendors/js:$(STATIC)/vendors/js

JS_TESTS_PATH = $(STATIC)/midoffice/tests
KARMA = ./node_modules/karma/bin/karma
KARMA_CONF = ./.webpack/karma.conf.babel.js
WEBPACK = ./node_modules/.bin/webpack
BABEL_NODE = ./node_modules/.bin/babel-node

PORT ?= 5000
TEST_ARGS ?= -v 2 --parallel
DJANGO_SERVER ?= runserver
DJANGO_SETTINGS_MODULE ?= $(PROJECT).settings
MANAGE_PY = $(PYTHON) manage.py
JETWING_ENV_VARS = SUBPARTNER=auth

configure_git:
	git config --local include.path ../.gitconfig

validate_apidocs:
	$(MANAGE_PY) generate_docs v2.0
	$(DRAFTER) apidocs_v2.0.apib
	$(MANAGE_PY) generate_docs v2.1
	$(DRAFTER) apidocs_v2.1.apib

build: install static download_locale syncdb test

build_companies_autocomplete:
	$(MANAGE_PY) run_companies_index_kafka_consumer --from-beginning --stop-after-last-message

build_users_autocomplete:
	$(MANAGE_PY) build_users_autocomplete

build_company_locations:
	$(MANAGE_PY) create_company_locations_index

celery: clean
	$(HONCHO) start celeryd celery_hyatt_fast celery_hyatt_slow

clean:
	find . -ignore_readdir_race -path "*/__pycache__/*" -delete
	find . -ignore_readdir_race -type d -empty -delete
ifneq ($(VENV_SRC),)
	find $(VENV_SRC) -path "*/__pycache__/*" -delete
	find $(VENV_SRC) -type d -empty -delete
endif

devserver: clean
	$(MAKE) watch-static & $(MANAGE_PY) $(DJANGO_SERVER) 0.0.0.0:$(PORT)

run: devserver

pep8:
	$(PEP8) --statistics $(PROJECT)/ airapi/ midoffice/ auth/ common/ gateway/

pin_requirements:
	pip-compile --rebuild -v --upgrade requirements.in

eslint:
	$(NODE_BIN)/eslint $(STATIC)

server: clean
	PORT=$(PORT) $(HONCHO) start web

shell:
	$(MANAGE_PY) | grep shell_plus && $(MANAGE_PY) shell_plus || $(MANAGE_PY) shell

testpy: clean
	$(MANAGE_PY) test $(TEST_ARGS)

snapshots: clean
	$(MANAGE_PY) test $(TEST_ARGS) --snapshot-update

jetwing_testpy:
	$(JETWING_ENV_VARS) $(MANAGE_PY) test auth $(TEST_ARGS)

coveragepy:
	$(COVERAGE) erase
	$(COVERAGE) run ./manage.py test $(TEST_ARGS)
	$(JETWING_ENV_VARS) $(COVERAGE) run ./manage.py test auth $(TEST_ARGS)
	$(COVERAGE) combine

coveragepy_show: coveragepy
	$(COVERAGE) report -m
	$(COVERAGE) html
	open coverage/python/html/index.html


testjs:
	npm test

test: testpy testjs jetwing_testpy

install: clean
	$(PIP) install -r requirements.txt
	npm ci --verbose
	npm prune

clean-static:
	rm -rf $(STATIC)/dist/*
	rm -f $(STATIC)/static_file_versions.json
	rm -f $(STATIC)/webpack-assets.json

collect-static: clean-static
	$(MANAGE_PY) collect_static

static/js:
	$(WEBPACK) --env env=production --stats errors-only

static: download_locale collect-static
	$(MAKE) static/js
	$(MANAGE_PY) prepare_static
	$(MANAGE_PY) prepare_versions
	$(MANAGE_PY) compilemessages

upload-sentry-sources:
	$(MANAGE_PY) upload_sentry

watch-static:
	$(WEBPACK) --watch --progress --stats-colors

webpack-stats:
	$(WEBPACK) --profile --json stats.json

make_locale:
	env BABEL_ENV=l10n ./node_modules/.bin/babel static/midoffice/js/ \
        -d ./static/midoffice/js_translate/
	env BABEL_ENV=l10n ./node_modules/.bin/babel static/airborne/js/ \
        -d ./static/airborne/js_translate/
	$(MANAGE_PY) make_locale --all -d djangojs -e js,html
	rm -rf ./static/midoffice/js_translate/ ./static/airborne/js_translate/
	$(MANAGE_PY) make_locale --all -p "airborne" -p "static" -p "airapi" -p "maintenance" -p "aft_messages"
	$(MANAGE_PY) copy_locale fr fr_CA
	$(MANAGE_PY) dummy_locale

upload_locale:
	$(MANAGE_PY) upload_locale

download_locale:
	$(MANAGE_PY) download_locale

sync_locale: download_locale make_locale upload_locale

syncdb:
	$(MANAGE_PY) migrate --noinput
	$(MANAGE_PY) sync_starwood

.PHONY: check-missing-db-migrations
check-missing-db-migrations:
	@echo If the following command produces a \"linting\" error, then potentially you have a backward incompatible \
 		migration. Follow this instructions to fix: \
 		https://getgoing.atlassian.net/wiki/spaces/GI/pages/2346516497/How+to+make+safe+and+backward+compatible+data+DB+migrations+for+Django+apps+airborne+hyatt+etc.
	CHECK_MIGRATIONS=True $(MANAGE_PY) makemigrations --check --noinput --sql-analyser postgresql
	SUBPARTNER=auth CHECK_MIGRATIONS=True $(MANAGE_PY) makemigrations --check --noinput --sql-analyser postgresql

.PHONY: lint-db-migrations
lint-db-migrations:
	@echo If the following command produces an error, then potentially you have a backward incompatible \
 		migration. Follow this instructions to fix: \
 		https://getgoing.atlassian.net/wiki/spaces/GI/pages/2346516497/How+to+make+safe+and+backward+compatible+data+DB+migrations+for+Django+apps+airborne+hyatt+etc.
	CHECK_MIGRATIONS=True $(MANAGE_PY) lintmigrations --sql-analyser postgresql
	SUBPARTNER=auth CHECK_MIGRATIONS=True $(MANAGE_PY) lintmigrations --sql-analyser postgresql

hooks:
	pre-commit install --hook-type pre-commit --hook-type pre-push

# Actions which should be run after each airborne deploy
deploy_actions:
	$(MANAGE_PY) migrate --noinput
	$(MANAGE_PY) publish_docs -e ${BASE_ENV} -t ${APIARY_TOKEN}
	$(MANAGE_PY) publish_schema s3
	$(MANAGE_PY) publish_schema --derived s3
	$(MANAGE_PY) create_missing_feature_flags

reload_service:
	for s in `basename -s '.conf' -a /etc/init/airborne-*`; do sudo service $$s reload; done

reload_celerybeat:
	for s in `basename -s '.conf' -a /etc/init/celerybeat-*`; do sudo service $$s reload; done

# Simple fast commands to code/data dependencies
magic: clean install static syncdb

release.8.38:
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' \
		--permissions-codes \
		midoffice:companies:general:feature_toggles:view \
		midoffice:companies:general:feature_toggles:edit

release.8.38.post_cutover:

release.8.39:
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' 'Supplier Relations' 'Account Manager' 'Revenue Manager' \
		--permissions-codes \
		midoffice:companies:hotels:company_secured_hotels:view \
		midoffice:companies:hotels:company_secured_hotels:edit
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' \
		--permissions-codes \
		midoffice:companies:cars:cars_labeling:view \
		midoffice:companies:cars:cars_labeling:edit
	$(MANAGE_PY) modify_auth_app --app_name \
		airborne-jetwing \
		atlas-jetwing \
		bowman-jetwing \
		cessna-jetwing \
		fokker-jetwing \
		hyatt-jetwing \
		pilatus-jetwing \
        --allowed_endpoints '{"hyatt": ["/get_params_inheritance"]}'
	$(MANAGE_PY) migrate_users_with_cars_air_view_permission
	$(MANAGE_PY) migrate_users_with_cars_air_edit_permission

release.8.39.post_cutover:


release.8.40:
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' \
		--permissions-codes \
		midoffice:companies:hotels:travel_restrictions:view \
		midoffice:companies:hotels:travel_restrictions:edit \
		midoffice:companies:cars:travel_restrictions:view \
		midoffice:companies:cars:travel_restrictions:edit \
		midoffice:companies:flights:travel_restrictions:view \
		midoffice:companies:flights:travel_restrictions:edit

release.8.40.post_cutover:


release.8.41:


release.8.41.post_cutover:


release.8.42:
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' \
		--permissions-codes \
		midoffice:companies:hotels:omnibees_credentials:view \
		midoffice:companies:hotels:omnibees_credentials:edit


release.8.42.post_cutover:


release.8.43:


release.8.43.post_cutover:


release.8.44:
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' \
		--permissions-codes \
		midoffice:companies:flights:air_labeling:view \
		midoffice:companies:flights:air_labeling:edit

release.8.44.post_cutover:

release.8.45:
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' \
		--permissions-codes \
		midoffice:companies:flights:search_customizations:view \
		midoffice:companies:flights:search_customizations:edit



release.8.45.post_cutover:

release.8.46:
	$(MANAGE_PY) update_allowed_endpoints
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' \
		--permissions-codes \
		midoffice:companies:general:sso_configuration:view \
		midoffice:companies:general:sso_configuration:edit

release.8.46.post_cutover:

release.8.47:
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' \
		--permissions-codes \
		midoffice:companies:flights:custom_airport_hubs:view \
		midoffice:companies:flights:custom_airport_hubs:edit


release.8.47.post_cutover:

release.8.48:


release.8.48.post_cutover:
	$(MANAGE_PY) delete_granular_permissions \
	midoffice:companies:general:tspm_profile_sync:view \
	midoffice:companies:general:tspm_profile_sync:edit


release.8.49:
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' \
		--permissions-codes \
		midoffice:companies:flights:co2_emissions:view \
		midoffice:companies:flights:co2_emissions:edit


release.8.49.post_cutover:

release.8.50:
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' \
		--permissions-codes \
		midoffice:companies:rail:rail:view \
		midoffice:companies:rail:rail:edit


release.8.50.post_cutover:
	$(MANAGE_PY) delete_granular_permissions \
		midoffice:companies:general:travel_policy_text:view \
		midoffice:companies:general:travel_policy_text:edit \
		midoffice:companies:general:travel_arrangers:view \
		midoffice:companies:general:travel_arrangers:edit \
		midoffice:companies:hotels:cft_home_page_setup:edit \
		midoffice:companies:hotels:cft_home_page_setup:view \
		midoffice:companies:general:terms_conditions:view \
		midoffice:companies:general:terms_conditions:edit
	$(MANAGE_PY) add_granular_permissions_to_groups \
        --groups 'Agent' --permissions-codes aft:unmasked_pnr:view

release.8.51:


release.8.51.post_cutover:


release.8.52:
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' \
		--permissions-codes \
		midoffice:agencies:general:invoice_collection:view \
		midoffice:agencies:general:invoice_collection:edit \
		midoffice:companies:general:invoice_collection:view \
		midoffice:companies:general:invoice_collection:edit \
		midoffice:companies:cars:segment_configuration:view \
		midoffice:companies:cars:segment_configuration:edit \
		midoffice:companies:general:agent_chat:view \
		midoffice:companies:general:agent_chat:edit
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' \
		--permissions-codes \
		midoffice:companies:flights:sabre_ndc:view \
		midoffice:companies:flights:sabre_ndc:edit


release.8.52.post_cutover:

release.8.53:


release.8.53.post_cutover:


release.8.54:
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' \
		--permissions-codes \
		midoffice:companies:general:pnr_formatting:view \
		midoffice:companies:general:pnr_formatting:edit
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' \
		--permissions-codes \
		midoffice:companies:flights:search_sorting_customization:view \
		midoffice:companies:flights:search_sorting_customization:edit
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Agent' 'Admin' 'Site Admin' 'Supplier Relations' 'Advertising Manager' 'Revenue Manager' \
		--permissions-codes \
		aft:booking_records:edit \
		aft:check_external_booking:view \
		aft:check_external_booking:edit
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' 'Supplier Relations' 'Advertising Manager' 'Revenue Manager' \
		--permissions-codes \
		aft:booking_records:extra_features:view
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' \
		--permissions-codes \
		midoffice:agencies:flights:policy:view \
		midoffice:agencies:flights:policy:edit \

release.8.54.post_cutover:
	$(MANAGE_PY) delete_granular_permissions \
		midoffice:booking_records:edit \
		midoffice:check_external_booking:view \
		midoffice:check_external_booking:edit
 	# Fixing the permission that was accidentally added to account managers
	$(MANAGE_PY) delete_granular_permissions \
		supplier_hotel_ids:view
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' 'Supplier Relations' 'Advertising Manager' 'Revenue Manager' \
		--permissions-codes \
		supplier_hotel_ids:view

release.8.55:


release.8.55.post_cutover:


release.8.56:


release.8.56.post_cutover:
	$(MANAGE_PY) delete_granular_permissions cft:login
	$(MANAGE_PY) remove_old_auth_groups


release.8.57:
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' \
		--permissions-codes \
		midoffice:agencies:general:tripsource_credits_and_unused_tickets:view \
		midoffice:agencies:general:tripsource_credits_and_unused_tickets:edit \
		midoffice:companies:general:tripsource_credits_and_unused_tickets:view \
		midoffice:companies:general:tripsource_credits_and_unused_tickets:edit


release.8.57.post_cutover:


release.8.58:


release.8.58.post_cutover:
	$(MANAGE_PY) delete_granular_permissions midoffice:reporting


release.8.59:


release.8.59.post_cutover:


release.8.60:
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' \
		--permissions-codes \
		midoffice:companies:cars:cars_home_page:view \
		midoffice:companies:cars:cars_home_page:edit


release.8.60.post_cutover:


release.8.61:

release.8.61.post_cutover:


release.8.62:
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' \
		--permissions-codes midoffice:groups:user_without_group:view
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' \
		--permissions-codes \
		midoffice:companies:flights:amadeus_gds:view \
		midoffice:companies:flights:amadeus_gds:edit
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' \
		--permissions-codes \
		midoffice:agencies:flights:office_hours:view \
		midoffice:agencies:flights:office_hours:edit
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' \
		--permissions-codes \
		midoffice:companies:rail:trainline:view \
		midoffice:companies:rail:trainline:edit \
		midoffice:companies:rail:deutschebahn:view \
		midoffice:companies:rail:deutschebahn:edit

release.8.62.post_cutover:


release.8.63:
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' \
		--permissions-codes \
		midoffice:companies:rail:trainline:view \
		midoffice:companies:rail:trainline:edit \
		midoffice:companies:rail:deutschebahn:view \
		midoffice:companies:rail:deutschebahn:edit
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' \
		--permissions-codes \
		midoffice:companies:flights:sabre_content_control:view \
		midoffice:companies:flights:sabre_content_control:edit
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' \
		--permissions-codes \
		midoffice:companies:hotels:hotel_exclusion_rules:view \
		midoffice:companies:hotels:hotel_exclusion_rules:edit


release.8.63.post_cutover:


release.8.64:


release.8.64.post_cutover:


release.8.65:
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' \
		--permissions-codes \
		midoffice:companies:rail:multiple_passengers:view \
        midoffice:companies:rail:multiple_passengers:edit \
        midoffice:companies:rail:payment_options:view \
        midoffice:companies:rail:payment_options:edit


release.8.65.post_cutover:


release.8.66:
	$(MANAGE_PY) add_granular_permissions_to_groups \
		--groups 'Admin' 'Site Admin' \
		--permissions-codes \
		midoffice:companies:flights:amadeus_content_control:view \
		midoffice:companies:flights:amadeus_content_control:edit

release.8.66.post_cutover:


release.8.67:


release.8.67.post_cutover:


release.8.68:


release.8.68.post_cutover:


release.8.69:


release.8.69.post_cutover:


release.8.70:


release.8.70.post_cutover:


release.8.71:


release.8.71.post_cutover:


# WARNING: when you adding anything under 'release.X.X' target make sure that
# it is idempotent. These targets are automatically run several times during
# UAT and PROD deployment while airborne of previous version is still running
# and serving user requests.
# BUT on staging you MUST RUN THEM MANUALLY!
#
# So, your command should:
#     1. Not break running previous release version
#     2. Handle multiple runs
#     3. Not change what was changed by previous runs
#
# You should:
#     1. Run the command manually on staging