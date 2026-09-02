"""Percentiles from a Prometheus histogram, read out of a metrics dump.

Interpolates linearly inside the bucket a quantile falls in, which is what
histogram_quantile does. The resolution is the bucket width: a p95 reported as
900 ms means "somewhere in the bucket ending at 900 ms", not 900 ms exactly.

Usage: histogram_quantiles.py <metrics-file> <metric-name> <label> <value>
Prints: "<p50 ms> <p95 ms> <observations>"
"""

import re
import sys


def main() -> None:
    path, metric, label, value = sys.argv[1:5]
    with open(path, encoding="utf-8") as handle:
        text = handle.read()

    pattern = re.compile(
        r"^" + re.escape(metric) + r"_bucket\{[^}]*"
        + re.escape(label) + r'="' + re.escape(value) + r'"[^}]*'
        r'le="([^"]+)"\}\s+([0-9.e+-]+)$',
        re.M,
    )

    buckets = sorted(
        (float(m.group(1)), float(m.group(2))) for m in pattern.finditer(text)
    )
    if not buckets or buckets[-1][1] == 0:
        print("0 0 0")
        return

    total = buckets[-1][1]

    def quantile(p: float) -> float:
        want = p * total
        previous_bound, previous_count = 0.0, 0.0
        for bound, count in buckets:
            if count >= want:
                if bound == float("inf"):
                    return previous_bound
                if count == previous_count:
                    return bound
                span = (want - previous_count) / (count - previous_count)
                return previous_bound + (bound - previous_bound) * span
            previous_bound, previous_count = bound, count
        return buckets[-1][0]

    print(f"{quantile(0.50) * 1000:.1f} {quantile(0.95) * 1000:.1f} {int(total)}")


if __name__ == "__main__":
    main()
