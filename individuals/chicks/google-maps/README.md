# data-curated/individuals/chicks/google-maps

My google maps reviews from Google Takeout.

## Expert Reviewer - Helpfulness

It seems like the helpfulness counter for me has been stuck at
46/50 so I wanted to confirm that I had actually reached this goal.

```bash
% ./process-reviews.sh
many len sum note
   1 242 51 enough?
   1 237 52 enough?
   1 235 53 enough?
   1 234 54 enough?
   1 230 55 enough?
   1 229 56 enough?
   1 228 57 enough?
   2 226 59 enough?
   2 222 61 enough?
   1 219 62 enough?
   1 214 63 enough?
   1 213 64 enough?
   1 209 65 enough?
   1 207 66 enough?
   1 205 67 enough?
```

The columns are:

- `many` - how many reviews of this length
- `len` - the character length of the reviews
- `sum` - the cumulitive sum of the `many` column
- `note` - a flag of `enough?` if it seems like we've achieved it.

So it seems like I shoudl be at 67/50, not 46/50.

## Files

- `Reviews.json` - my google takeout of google maps reviews
- `process-reviews.sh` - reprocess takeout json to see if you've gotten to 50x
  200char reviews
- `review-count.txt` - intermediate file regnerated by `process-reviews.sh`
- `reviews.txt` - intermediate file regnerated by `process-reviews.sh`
