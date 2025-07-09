#!/usr/bin/env bash

#set -x # tracing

out_file="character_reference.md"

> $out_file

for character in $(toml get ./characters.toml '.' | jq -r 'keys.[]')
do
	echo "c=$character"

	image_file=$(toml get -r ./characters.toml "${character}.image_file")

	(
		echo "## $character"
		echo ""
		echo "![$character]($image_file)"
		echo ""
	) >> $out_file
done
