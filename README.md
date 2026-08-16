# Portfolio Performance API

API Ruby (Sinatra + Puma) che legge un file `.portfolio` (da Google Drive o da disco) e restituisce i **saldi dei conti liquidi e dei conti titoli**. Include anche due utility: import movimenti Fineco e sync bidirezionale con Google Sheets.

File demo per prove e test: `test/test.portfolio` (password `portfolio`).

## Setup

```bash
cp env.example .env
bundle install
```

Per Drive/Sheets: abilita **Google Drive API** e **Google Sheets API**, crea un **service account**, scarica il JSON. Condividi i file con l’email `…@….iam.gserviceaccount.com` (Viewer per la sola API, **Editor** per sync e test). Drive risponde 404 se il service account non ha accesso.

| Variabile | Serve per | Descrizione |
| --- | --- | --- |
| `API_KEY` | API | Chiave in `X-Api-Key`, `Authorization: Bearer` o `?apikey=` |
| `PORTFOLIO_PASSWORD` | API, Fineco, sync | Password del `.portfolio` cifrato |
| `PORTFOLIO_GOOGLE_DRIVE_FILE_ID` | API, sync | Id (o URL) del `.portfolio` su Drive |
| `PORTFOLIO_FILE` | API locale | Path a un `.portfolio` su disco, se Drive non è configurato |
| `GOOGLE_SERVICE_ACCOUNT_JSON` | Drive/Sheets | Contenuto JSON del service account |
| `GOOGLE_APPLICATION_CREDENTIALS` | Drive/Sheets | Alternativa: path al JSON |
| `SYNC_GOOGLE_DRIVE_FILE_ID` | sync | Spreadsheet di sync |
| `SYNC_GOOGLE_DRIVE_FILE_ID_TEST` | test live | Spreadsheet usato dai test di sync |
| `SYNC_GOOGLE_DRIVE_FILE_SKIP_ROWS` | sync | Righe da non toccare in cima a ogni foglio. Default `0` |
| `SYNC_GOOGLE_DRIVE_ROWS_CHUNK` | sync | Righe scritte per richiesta Sheets. Default `100` |
| `SYNC_GOOGLE_DRIVE_PREVIEW_ROWS` | sync | Righe visibili per lista nel preview. Default `20` |
| `IMPORT_FINECO_XLS_SKIP_LINES` | Fineco | Righe da saltare nell’export. Default `13` |
| `CACHE_TTL_MINUTES` | API | Default `15` |
| `INCLUDE_RETIRED` | API | Default `true` |
| `PORT` | API | Default `9292` |

## API

Espone i saldi del portafoglio in JSON o CSV. Scarica il `.portfolio` da Drive (o legge `PORTFOLIO_FILE`), lo decifra, calcola il saldo di ogni conto deposito e il valore di mercato di ogni conto titoli, e tiene il risultato in cache per `CACHE_TTL_MINUTES` (`?nocache` forza un refresh).

```bash
# Prova locale con il file demo, senza Drive
API_KEY=dev PORTFOLIO_FILE=test/test.portfolio PORTFOLIO_PASSWORD=portfolio \
  bundle exec puma -C config/puma.rb

curl -sS -H "X-Api-Key: dev" http://127.0.0.1:9292/health
curl -sS -H "X-Api-Key: dev" http://127.0.0.1:9292/accounts
curl -sS -H "X-Api-Key: dev" http://127.0.0.1:9292/accounts.json
curl -sS -H "X-Api-Key: dev" http://127.0.0.1:9292/accounts.csv
curl -sS "http://127.0.0.1:9292/accounts.csv?apikey=dev&locale=it"
curl -sS -H "X-Api-Key: dev" "http://127.0.0.1:9292/accounts?nocache"
```

`GET /accounts` e `GET /accounts.json` → JSON. `GET /accounts.csv` → CSV UTF-8, separatore `;` (decimali `.` con `locale=en`, `,` con `locale=it`). `GET /health` è pubblico. `GET /` è uguale a `/accounts`.

Ogni riga ha `kind`: `deposit` (cassa) o `securities` (titoli, senza conversione FX). I conti titoli includono `reference_account_uuid`.

Docker:

```bash
docker build -t portfolio-performance-api .
docker run --env-file .env -p 9292:80 portfolio-performance-api
```

## Import Fineco

Importa i movimenti da un export Fineco (`.xls` / `.xlsx`) in un `.portfolio` protobuf. Propone solo le righe con data **successiva** all’ultima transazione del conto; tu scegli quali importare. Usa `Data_Valuta`, `Entrate` → `DEPOSIT`, `Uscite` → `REMOVAL`. La note è `Descrizione Descrizione_Completa Categoria: Moneymap`. Prima di scrivere crea un backup `nome-YYYYMMDDTHHMMSS.portfolio`.

Serve un terminale interattivo e `bundle install` senza `BUNDLE_WITHOUT=utils`. Chiudi Portfolio Performance prima di importare.

```bash
ruby utils/import-fineco.rb EUR010069756 $HOME/finance/portfolio1.portfolio ./movements.xlsx
```

↑/↓ per muoversi, spazio per selezionare, prima riga `toggle all`, Invio per confermare, poi `y`. Password: `PORTFOLIO_PASSWORD` oppure viene chiesta.

## Sync spreadsheet

Allinea in entrambi i sensi i movimenti di ogni conto deposito e conto titoli del `.portfolio` su Drive (`PORTFOLIO_GOOGLE_DRIVE_FILE_ID`) con uno spreadsheet (`SYNC_GOOGLE_DRIVE_FILE_ID`). Per ogni account prepara due piani, mostra le liste **PORTFOLIO** e **SPREADSHEET**, poi chiede cosa scrivere.

Identità: hash SHA-256 di conto + data + importo + descrizione + destinazione (ricalcolato a runtime, non salvato). Create-or-update, senza cancellare. Il tipo nello spreadsheet vince; l’UUID di Portfolio Performance viene conservato. `amount` è un numero con decimale `.` (foglio locale US). Scrittura a blocchi di `SYNC_GOOGLE_DRIVE_ROWS_CHUNK` righe.

Condividi spreadsheet e `.portfolio` come **Editor**. Chiudi Portfolio Performance prima del sync.

```bash
ruby bin/utils/sync.rb
```

Tasti: ↑/↓ una riga, `u`/`v` pagina, **S** solo spreadsheet, **P** solo portfolio, **B** entrambi, **Esc** salta l’account. Il `.portfolio` viene ricaricato su Drive una sola volta alla fine se almeno un account ha scelto P o B.

Colonne: `date`, `type`, `amount`, `currency`, `description`, `destination`, `uuid`. `SYNC_GOOGLE_DRIVE_FILE_SKIP_ROWS` lascia intatte le prime N righe.

## Test

Il file demo `test/test.portfolio` (password `portfolio`) è il portafoglio di esempio di Portfolio Performance. I test di sync lo usano sempre. I test live (`test/sync_sheets_test.rb`) svuotano lo spreadsheet `SYNC_GOOGLE_DRIVE_FILE_ID_TEST`, creano un foglio per ogni conto e **lasciano i dati** alla fine (niente cleanup). Lo spreadsheet deve essere condiviso come Editor con il service account.

```bash
# Tutta la suite (i test live si saltano se manca SYNC_GOOGLE_DRIVE_FILE_ID_TEST)
bundle exec rake test

# Solo sync in memoria sul file demo
bundle exec rake test TEST=test/sync_demo_test.rb

# Solo sync live verso lo spreadsheet di test
bundle exec rake test TEST=test/sync_sheets_test.rb
```

Senza `.env` completo la suite resta verde: i test Google vengono skippati.

## Deploy (Kamal)

Serve un VPS con Docker e SSH, e un dominio che punta al server. Le immagini restano sul registry locale (`localhost:5555`).

1. In `config/deploy.yml` imposta l’IP del server e `proxy.host`.
2. `set -a && source .env && set +a`
3. Primo setup: `bundle exec kamal setup`
4. Deploy successivi: `bundle exec kamal deploy`

`kamal-proxy` ascolta 80/443, certificato Let’s Encrypt, healthcheck `GET /health`.

```bash
bundle exec kamal logs
bundle exec kamal shell
```
