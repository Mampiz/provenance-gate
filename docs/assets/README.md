# Recordings

Real runs against the real cluster, at the speed the system actually answered.
Nothing here is staged and nothing is re-timed.

| | |
|---|---|
| `verify-f3.gif` | The three admissions. The claim the project exists for, made checkable. |
| `verify-f4.gif` | The same guarantee through `webapp-operator`, end to end. |

## Re-rendering

The `.cast` files are committed next to the GIFs. They are a few KB and they are
what makes these assets maintainable: re-rendering does not need a cluster.

```bash
./bin/agg --font-size 16 --theme asciinema --idle-time-limit 2 \
  docs/assets/verify-f3.cast docs/assets/verify-f3.gif
```

## Re-recording

Needs a running cluster with the webhook deployed:

```bash
make bootstrap deploy webapp-operator
./hack/record.sh verify-f3 verify-f3
./hack/record.sh verify-f4 verify-f4
```

`hack/record.sh` captures the run with millisecond timestamps and
`hack/build-cast.py` turns it into an asciicast. Three things in there are not
optional, and each of them silently ruins a recording rather than failing:

- **`grep --line-buffered`.** Without it grep holds its output until the pipe
  closes, every line is stamped at the same instant, and a thirty second run
  plays back in four.
- **Nothing wraps.** A wrapped line redraws the whole frame. Digests are
  abbreviated rather than dropped, because a heading with no lines under it
  reads as a broken run.
- **The terminal is exactly as tall as the content.** Empty rows at the bottom
  are a third of the frame spent on nothing.

The script writes the final frame to `/tmp/<name>-final.png`. Open it before
committing. A recording nobody looked at is how a GIF of a run that failed,
or that stopped three lines short of its verdict, ends up in a README.
