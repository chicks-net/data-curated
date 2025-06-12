#!/usr/bin/env bash


cat Reviews.json | jq '.features[].properties.review_text_published' | grep -v null > reviews.txt

awk '{print length}' reviews.txt | sort -nr | uniq -c > review-count.txt

echo "many len sum note"
cat review-count.txt | awk '{
	total += $1 ;
	note = "";
	if ($2 > 200 && total > 50) {
		note = "enough?";
	}
	print $0, total, note;
}' | grep enough
