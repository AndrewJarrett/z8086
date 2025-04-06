#!/bin/bash
shopt -s extglob

# Ensure we have built the latest program
zig build --release=fast

for bin in src/listings/!(*.*) ; do
	echo "Testing $bin..."

	# Disassemble the given binary
	./zig-out/bin/z8086 -d $bin > tmp.asm && 

	# Assemble the binary from the disassembly
	output=$(nasm tmp.asm -o tmpBin 2>&1)

	if [ ! -z "$output" ]; then
		echo -e "\033[31m[FAIL]\033[0m Error: $output"
	else 
		# Compare and fail the test if the original and new binary files differ
		differences=$(diff tmpBin $bin 2>&1)

		if [ ! -z "$differences" ]; then
			echo -e "\033[31m[FAIL]\033[0m Files differ: $differences"
		else
			echo -e "\033[32m[PASS]\033[0m"
		fi
	fi

	# Cleanup tmp files
	if test -f tmp.asm; then
		rm tmp.asm
	fi

	if test -f tmpBin; then
		rm tmpBin
	fi
done

