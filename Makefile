.PHONY: build test fmt lint slither coverage snapshot

build:
	forge build --sizes

test:
	forge test -vvv

fmt:
	forge fmt

lint:
	forge fmt --check

slither:
	slither .

coverage:
	forge coverage --report summary

snapshot:
	forge snapshot
