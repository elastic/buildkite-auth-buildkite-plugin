FROM buildkite/plugin-tester:v4.4.0@sha256:227f1ca092928541e52dc82a4af51943bc3e69451fe7eb4473e484f66e3a4447

RUN adduser --disabled-password --gecos "" plugin-tester
USER plugin-tester
