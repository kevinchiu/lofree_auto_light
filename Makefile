build/lofree-light: Sources/main.swift
	mkdir -p build
	swiftc -O -o $@ $<

.PHONY: install uninstall clean
install:
	./install.sh

uninstall:
	./uninstall.sh

clean:
	rm -rf build
