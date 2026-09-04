PYTHON ?= python3
TF_DIR := infra/terraform

.PHONY: check test terraform-init terraform-fmt terraform-validate yaml-check shell-check secret-scan web-host-loss-process web-host-loss-host web-host-loss-multi resilience-dashboard-dry-run resilience-dashboard-up resilience-dashboard-down

check: test terraform-fmt terraform-validate yaml-check shell-check secret-scan

test:
	$(PYTHON) -m unittest discover -s recovery/controller/tests -v
	$(PYTHON) -m unittest discover -s recovery/nat_failover -p 'test_*.py' -v
	$(PYTHON) -m unittest discover -s tests -p 'test_*.py' -v

terraform-init:
	terraform -chdir=$(TF_DIR) init -backend=false

terraform-fmt:
	terraform -chdir=$(TF_DIR) fmt -check -recursive

terraform-validate:
	terraform -chdir=$(TF_DIR) validate

yaml-check:
	$(PYTHON) -c 'import json,pathlib,yaml; files=list(pathlib.Path(".").rglob("*.yml"))+list(pathlib.Path(".").rglob("*.yaml")); [yaml.safe_load(p.read_text()) for p in files]; [json.loads(p.read_text()) for p in pathlib.Path("recovery/controller/tests/fixtures").glob("*.json")]; print(f"parsed {len(files)} YAML files")'

shell-check:
	bash -n recovery/controller/scripts/*.sh experiments/web-host-loss/*.sh experiments/aws-web-host-loss/*.sh observability/resilience-experiment/*.sh scripts/*.sh

secret-scan:
	@! git grep -nE '(AKIA[0-9A-Z]{16}|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|hooks\.slack\.com/services/[A-Za-z0-9/_-]+)' -- ':!Makefile'
	@! git grep -nE 'expected_account_id[[:space:]]*=[[:space:]]*"[0-9]{12}"' -- ':!Makefile'
	@! git ls-files | grep -E '(^|/)(terraform\.tfstate([.]|$$)|terraform\.tfvars$$|[^/]+[.]pem$$|secrets[.]yml$$)'

web-host-loss-process:
	./experiments/web-host-loss/run-swarm-poc.sh process

web-host-loss-host:
	./experiments/web-host-loss/run-swarm-poc.sh host

web-host-loss-multi:
	./experiments/web-host-loss/run-multi-replica-poc.sh

resilience-dashboard-dry-run:
	./observability/resilience-experiment/run-local-dry-run.sh

resilience-dashboard-up:
	docker compose -f observability/resilience-experiment/docker-compose.yml down --remove-orphans
	rm -f experiments/aws-web-host-loss/artifacts/live-state.json
	docker compose -f observability/resilience-experiment/docker-compose.yml up -d

resilience-dashboard-down:
	docker compose -f observability/resilience-experiment/docker-compose.yml down --remove-orphans
