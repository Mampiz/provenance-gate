# The image the F3 verifier uses as a subject. It runs nothing and is never
# started: admission happens before a pull, so what matters is that it exists in
# the registry and that the right attestations are or are not attached to it.
#
# Kept trivial on purpose. Rebuilding the real Go image three times per CI run
# to produce test subjects would make the suite slow for no extra assurance.
FROM gcr.io/distroless/static-debian13:nonroot
COPY marker /marker
