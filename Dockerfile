FROM buildkite/plugin-tester:v5.0.0@sha256:67e8715cbbb456759d2fcaf8c016ee70c19aa86bc71aab7ff117bd45f1340a39

RUN adduser --disabled-password --gecos "" plugin-tester
USER plugin-tester
