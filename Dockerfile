FROM python:3.10-slim-bookworm AS builder

RUN apt-get clean
RUN apt-get update
RUN apt-get install -y curl pkg-config build-essential libnss-myhostname

RUN curl -sSL https://install.python-poetry.org | python3 -
ENV PATH="/root/.local/bin:$PATH"

WORKDIR /app

# Copy the entire source code first to ensure all modules are available
COPY . .

RUN curl -sSL https://install.python-poetry.org | python3 -
ENV PATH="/root/.local/bin:$PATH"

RUN mkdir -p data

ENV POETRY_NO_INTERACTION=1 \
    POETRY_VIRTUALENVS_IN_PROJECT=1 \
    POETRY_VIRTUALENVS_CREATE=1 \
    VIRTUAL_ENV=/app/.venv \
    PATH="/app/.venv/bin:$PATH" \
    LNBITS_PORT="5000" \
    LNBITS_HOST="0.0.0.0" \
    LNBITS_BACKEND_WALLET_CLASS="FakeWallet" \
    LNBITS_DEBUG="true" \
    PYTHONUNBUFFERED=1

# Install all dependencies including dev dependencies
RUN poetry install

FROM python:3.10-slim-bookworm

# needed for backups postgresql-client version 14 (pg_dump)
RUN apt-get update && apt-get -y upgrade && \
    apt-get -y install gnupg2 curl lsb-release && \
    sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list' && \
    curl -s https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - && \
    apt-get update && \
    apt-get -y install postgresql-client-14 postgresql-client-common && \
    apt-get clean all && rm -rf /var/lib/apt/lists/*

RUN curl -sSL https://install.python-poetry.org | python3 -
ENV PATH="/root/.local/bin:$PATH"

ENV POETRY_NO_INTERACTION=1 \
    POETRY_VIRTUALENVS_IN_PROJECT=1 \
    POETRY_VIRTUALENVS_CREATE=1 \
    VIRTUAL_ENV=/app/.venv \
    PATH="/app/.venv/bin:$PATH"

WORKDIR /app

# Copy the entire source code and virtual environment
COPY --from=builder /app .

ENV LNBITS_PORT="5000" \
    LNBITS_HOST="0.0.0.0" \
    LNBITS_BACKEND_WALLET_CLASS="FakeWallet"

EXPOSE 5000

CMD ["sh", "-c", "poetry run lnbits --port $LNBITS_PORT --host $LNBITS_HOST"]
