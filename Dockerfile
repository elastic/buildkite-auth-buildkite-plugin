FROM buildkite/plugin-tester:v4.3.0@sha256:86c728d8526e22f5d26c1b65e2cae1dfb2d9767fe24d560563895d051b258c84

RUN adduser --disabled-password --gecos "" plugin-tester
USER plugin-tester
