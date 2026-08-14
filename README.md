# Portfolio Performance API

API Ruby (Sinatra + Puma) che scarica un file `.portfolio` cifrato da Google Drive, lo decifra e restituisce i **saldi dei conti liquidi e dei conti titoli** in JSON o CSV.

## Cosa fa

1. Autenticazione con API key: header `X-Api-Key`, `Authorization: Bearer …`, oppure query string `?apikey=`, valore da `API_KEY`
2. Download del file da Google Drive con un service account
3. Decrypt AES-128/256 come Portfolio Performance (PBKDF2-HMAC-SHA1, 65536 iterazioni)
4. Lettura XML o protobuf (il formato binario interno)
5. Calcolo del saldo per ogni conto deposito (`Account#getCurrentAmount`) e del valore di mercato per ogni conto titoli
6. Cache in memoria per `CACHE_TTL_MINUTES` minuti; `?nocache` forza un nuovo download

## Setup Google Drive

1. Crea un progetto su Google Cloud e abilita **Google Drive API**
2. Crea un **service account**, scarica il JSON della chiave
3. Condividi il file `.portfolio` (Viewer) con l’email del service account (`…@….iam.gserviceaccount.com`). Drive risponde 404 se il service account non ha accesso, anche se il link si apre nel browser.
4. Copia l’id del file dall’URL (`/d/<FILE_ID>/` oppure `?id=<FILE_ID>`).

## Configurazione

Copia `env.example` in `.env`:

```bash
cp env.example .env
```

| Variabile | Obbligatoria | Descrizione |
| --- | --- | --- |
| `API_KEY` | sì | Chiave in `X-Api-Key`, `Authorization: Bearer` o `?apikey=` |
| `PORTFOLIO_PASSWORD` | per file cifrati | Password del `.portfolio` |
| `GOOGLE_DRIVE_FILE_ID` | sì* | Id (o URL) del file su Drive |
| `GOOGLE_SERVICE_ACCOUNT_JSON` | sì* | Contenuto JSON del service account |
| `GOOGLE_APPLICATION_CREDENTIALS` | alternativa | Path al JSON del service account |
| `CACHE_TTL_MINUTES` | no | Default `15` |
| `PORTFOLIO_FILE` | no | File locale, utile in sviluppo/test se Drive non è configurato |
| `INCLUDE_RETIRED` | no | Default `true`. `false` esclude i conti archiviati |
| `API_KEY_HEADER` | no | Default `X-Api-Key` |
| `PORT` | no | Default `9292` |

\* In produzione usa Drive. In locale puoi puntare `PORTFOLIO_FILE` a una copia del `.portfolio`.

## Avvio

```bash
bundle install
bundle exec puma -C config/puma.rb
```

Docker:

```bash
docker build -t portfolio-performance-api .
docker run --env-file .env -p 9292:80 portfolio-performance-api
```

## Deploy (Kamal)

Serve un VPS con Docker e SSH, e un dominio che punta al server. Le immagini restano sul registry locale (`localhost:5555`): Kamal lo avvia sul Mac e lo espone al VPS con un tunnel SSH, senza Docker Hub o GHCR.

1. In `config/deploy.yml` imposta l’IP del server e `proxy.host`.
2. Carica i secret e fai il primo setup:

```bash
set -a && source .env && set +a
bundle exec kamal setup
```

I deploy successivi:

```bash
set -a && source .env && set +a
bundle exec kamal deploy
```

`kamal-proxy` ascolta 80/443, ottiene il certificato Let’s Encrypt e inoltra a Puma sulla porta 80 del container. Healthcheck: `GET /health`.

```bash
bundle exec kamal logs
bundle exec kamal shell
```

## Uso

```bash
curl -sS -H "X-Api-Key: $API_KEY" http://127.0.0.1:9292/accounts
curl -sS -H "X-Api-Key: $API_KEY" http://127.0.0.1:9292/accounts.json
curl -sS -H "X-Api-Key: $API_KEY" http://127.0.0.1:9292/accounts.csv
curl -sS "http://127.0.0.1:9292/accounts.csv?apikey=$API_KEY"
curl -sS -H "X-Api-Key: $API_KEY" "http://127.0.0.1:9292/accounts?nocache"
```

Esempio di risposta:

```json
{
  "base_currency": "EUR",
  "version": 70,
  "accounts": [
    {
      "uuid": "…",
      "kind": "deposit",
      "name": "Conto corrente",
      "currency": "EUR",
      "retired": false,
      "balance": 875.0,
      "balance_cents": 87500
    }
  ],
  "totals": [{ "currency": "EUR", "balance": 990.01, "balance_cents": 99001 }],
  "file": { "source": "google_drive", "name": "wealth.portfolio", "modified_at": "…" },
  "format": "protobuf",
  "cached": false,
  "cached_at": "2026-08-14T20:00:00Z",
  "expires_at": "2026-08-14T20:15:00Z"
}
```

`GET /accounts` e `GET /accounts.json` restituiscono JSON. `GET /accounts.csv` restituisce un CSV (UTF-8, separatore `;`, decimali con virgola) importabile in Google Sheets: **File → Importa → Carica**, tipo separatore *punto e virgola*, oppure `IMPORTDATA("http://…/accounts.csv?apikey=…")`.

In development Sinatra ricarica i file in `lib/` a ogni richiesta, senza riavviare Puma.

`GET /health` è pubblico. `GET /` è uguale a `GET /accounts`. Header, Bearer e `?apikey=` sono equivalenti; se è presente l’header, vince lui.

Ogni riga ha `kind`: `deposit` (conto liquido, saldo da movimenti di cassa) oppure `securities` (conto titoli, valore di mercato al prezzo più recente, senza conversione FX). I conti titoli includono anche `reference_account_uuid`.

## Test

```bash
bundle exec rake test
```
