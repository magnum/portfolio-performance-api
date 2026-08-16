# frozen_string_literal: true

require_relative "test_helper"
require "date"
require "fileutils"
require "tmpdir"

require_relative "../lib/portfolio_performance_api/fineco_xls"
require_relative "../lib/portfolio_performance_api/fineco_import"
require_relative "../lib/portfolio_performance_api/portfolio_store"
require_relative "../lib/portfolio_performance_api/checkbox_selection"

class FinecoImportTest < Minitest::Test
  include PortfolioFixtures

  def test_parse_italian_amounts_and_dates
    rows = PortfolioPerformanceApi::FinecoXls.parse_rows([
      ["Estratto conto Fineco"],
      [],
      ["Data_Operazione", "Data_Valuta", "Entrate", "Uscite", "Descrizione"],
      ["01/06/2024", "01/06/2024", "1.234,56", "", "Stipendio"],
      ["02/06/2024", "02/06/2024", "", "12,00", "Commissione"],
      ["not-a-date", "not-a-date", "10,00", "", "skip"],
      ["03/06/2024", "03/06/2024", "10,00", "", ""]
    ])

    assert_equal 2, rows.size
    assert_equal Date.new(2024, 6, 1), rows[0].date
    assert_equal "Stipendio", rows[0].description
    assert_equal 123_456, rows[0].amount_cents
    assert_equal :DEPOSIT, rows[0].type
    assert_equal Date.new(2024, 6, 2), rows[1].date
    assert_equal 1_200, rows[1].amount_cents
    assert_equal :REMOVAL, rows[1].type
  end

  def test_uses_data_valuta_and_builds_note
    rows = PortfolioPerformanceApi::FinecoXls.parse_rows([
      ["Data_Operazione", "Data_Valuta", "Entrate", "Uscite", "Descrizione", "Descrizione_Completa", "Stato", "Moneymap"],
      [Date.new(2026, 8, 14), Date.new(2026, 8, 12), nil, -83.13, "Pagamento Visa Debit", "IPER LONATO", "Contabilizzato", "Alimentari"],
      ["-", Date.new(2026, 8, 15), 4756.96, nil, "Cambio valuta", "Compravendita Divise", "Autorizzato", nil],
      [Date.new(2026, 8, 14), Date.new(2026, 8, 14), 2432, nil, "Stipendio", "Ord: INCODE", "Contabilizzato", "Stipendio"]
    ])

    assert_equal 3, rows.size
    assert_equal Date.new(2026, 8, 12), rows[0].date
    assert_equal :REMOVAL, rows[0].type
    assert_equal 8_313, rows[0].amount_cents
    assert_equal "Pagamento Visa Debit IPER LONATO Categoria: Alimentari", rows[0].description
    assert_equal Date.new(2026, 8, 15), rows[1].date
    assert_equal :DEPOSIT, rows[1].type
    assert_equal 475_696, rows[1].amount_cents
    assert_equal "Cambio valuta Compravendita Divise", rows[1].description
    assert_equal "Stipendio Ord: INCODE Categoria: Stipendio", rows[2].description
  end

  def test_skip_lines_uses_default_fineco_columns
    preamble = Array.new(13) { |index| ["meta #{index}"] }
    rows = PortfolioPerformanceApi::FinecoXls.parse_rows(
      preamble + [
        ["-", Date.new(2026, 8, 15), nil, -99, "VISA DEBIT", "CRYPTO TAX - KOIN...", "Autorizzato", nil],
        [Date.new(2026, 8, 14), Date.new(2026, 8, 12), nil, -22.5, "Pagamento Visa Debit", "CAFFETT.GELAT.", "Contabilizzato", "Hotel Ristoranti e Viaggi"]
      ],
      skip_lines: 13
    )

    assert_equal 2, rows.size
    assert_equal Date.new(2026, 8, 15), rows[0].date
    assert_equal :REMOVAL, rows[0].type
    assert_equal 9_900, rows[0].amount_cents
    assert_equal "VISA DEBIT CRYPTO TAX - KOIN...", rows[0].description
    assert_equal "Pagamento Visa Debit CAFFETT.GELAT. Categoria: Hotel Ristoranti e Viaggi", rows[1].description
  end

  def test_default_skip_lines_from_env
    previous = ENV["IMPORT_FINECO_XLS_SKIP_LINES"]
    ENV.delete("IMPORT_FINECO_XLS_SKIP_LINES")
    assert_equal 13, PortfolioPerformanceApi::FinecoXls.default_skip_lines
    ENV["IMPORT_FINECO_XLS_SKIP_LINES"] = "12"
    assert_equal 12, PortfolioPerformanceApi::FinecoXls.default_skip_lines
  ensure
    if previous.nil?
      ENV.delete("IMPORT_FINECO_XLS_SKIP_LINES")
    else
      ENV["IMPORT_FINECO_XLS_SKIP_LINES"] = previous
    end
  end

  def test_parse_signed_importo_column
    rows = PortfolioPerformanceApi::FinecoXls.parse_rows([
      ["Data", "Descrizione", "Importo"],
      [Date.new(2024, 7, 1), "Accredito", "100,00"],
      ["02/07/2024", "Addebito", "-25,50"]
    ])

    assert_equal :DEPOSIT, rows[0].type
    assert_equal 10_000, rows[0].amount_cents
    assert_equal :REMOVAL, rows[1].type
    assert_equal 2_550, rows[1].amount_cents
  end

  def test_newer_than_filters_strictly_after_last_date
    rows = [
      PortfolioPerformanceApi::FinecoXls::Row.new(date: Date.new(2024, 1, 10), description: "old", amount_cents: 100, type: :DEPOSIT),
      PortfolioPerformanceApi::FinecoXls::Row.new(date: Date.new(2024, 1, 15), description: "same", amount_cents: 100, type: :DEPOSIT),
      PortfolioPerformanceApi::FinecoXls::Row.new(date: Date.new(2024, 1, 16), description: "new", amount_cents: 100, type: :DEPOSIT)
    ]

    newer = PortfolioPerformanceApi::FinecoImport.newer_than(rows, Date.new(2024, 1, 15))
    assert_equal ["new"], newer.map(&:description)
    assert_equal rows, PortfolioPerformanceApi::FinecoImport.newer_than(rows, nil)
  end

  def test_find_account_by_name_and_uuid
    client = protobuf_client
    assert_equal "acc-cash", PortfolioPerformanceApi::FinecoImport.find_account(client, "Conto corrente").uuid
    assert_equal "acc-cash", PortfolioPerformanceApi::FinecoImport.find_account(client, "conto corrente").uuid
    assert_equal "acc-savings", PortfolioPerformanceApi::FinecoImport.find_account(client, "acc-savings").uuid
    assert_nil PortfolioPerformanceApi::FinecoImport.find_account(client, "missing")
  end

  def test_last_transaction_date_and_proto_mapping
    client = protobuf_client
    client.transactions << PortfolioPerformanceApi::Proto::PTransaction.new(
      uuid: "tx-dated",
      type: :DEPOSIT,
      account: "acc-cash",
      date: Google::Protobuf::Timestamp.new(seconds: Time.utc(2024, 3, 10).to_i),
      currencyCode: "EUR",
      amount: 500
    )

    assert_equal Date.new(2024, 3, 10), PortfolioPerformanceApi::FinecoImport.last_transaction_date(client, "acc-cash")
    assert_nil PortfolioPerformanceApi::FinecoImport.last_transaction_date(client, "acc-savings")

    row = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2024, 3, 11),
      description: "Bonifico ricevuto",
      amount_cents: 25_000,
      type: :DEPOSIT
    )
    account = PortfolioPerformanceApi::FinecoImport.find_account(client, "Conto corrente")
    tx = PortfolioPerformanceApi::FinecoImport.build_transaction(row, account)

    assert_equal :DEPOSIT, tx.type
    assert_equal "acc-cash", tx.account
    assert_equal "EUR", tx.currencyCode
    assert_equal 25_000, tx.amount
    assert_equal "Bonifico ricevuto", tx.note
    assert_equal Time.utc(2024, 3, 11).to_i, tx.date.seconds
    assert tx.uuid.match?(/\A[\da-f-]{36}\z/)
    assert tx.has_updatedAt?
  end

  def test_backup_path_uses_timestamp
    at = Time.new(2026, 8, 16, 2, 10, 11)
    path = PortfolioPerformanceApi::PortfolioStore.backup_path("/tmp/portfolio1.portfolio", at: at)
    assert_equal "/tmp/portfolio1-20260816T021011.portfolio", path
  end

  def test_checkbox_toggle_all_and_navigation
    state = PortfolioPerformanceApi::CheckboxSelection.new(%w[a b c])
    assert_equal 0, state.cursor
    state.toggle
    assert state.all_selected?
    assert_equal %w[a b c], state.selected_items

    state.toggle
    refute state.all_selected?
    assert_equal [], state.selected_items

    state.down
    state.toggle
    assert_equal ["a"], state.selected_items
    state.down
    state.toggle
    assert_equal %w[a b], state.selected_items
    state.up
    state.up
    state.toggle
    assert state.all_selected?
  end

  def test_parse_html_saved_as_xls
    Dir.mktmpdir do |dir|
      path = File.join(dir, "transactions.xls")
      File.write(path, <<~HTML)
        <html><body><table>
          <tr><td>Estratto conto</td></tr>
          <tr><td>Data_Valuta</td><td>Descrizione</td><td>Entrate</td><td>Uscite</td></tr>
          <tr><td>15/07/2024</td><td>Bonifico</td><td>250,00</td><td></td></tr>
          <tr><td>16/07/2024</td><td>Canone</td><td></td><td>3,50</td></tr>
        </table></body></html>
      HTML

      rows = PortfolioPerformanceApi::FinecoXls.parse(path, skip_lines: 0)
      assert_equal 2, rows.size
      assert_equal Date.new(2024, 7, 15), rows[0].date
      assert_equal :DEPOSIT, rows[0].type
      assert_equal 25_000, rows[0].amount_cents
      assert_equal :REMOVAL, rows[1].type
      assert_equal 350, rows[1].amount_cents
    end
  end

  def test_parse_real_xls
    require "spreadsheet"

    Dir.mktmpdir do |dir|
      path = File.join(dir, "transactions.xls")
      book = Spreadsheet::Workbook.new
      sheet = book.create_worksheet
      sheet.row(0).replace ["FinecoBank"]
      sheet.row(2).replace ["Data_Valuta", "Descrizione", "Entrate", "Uscite"]
      sheet.row(3).replace [Date.new(2024, 8, 1), "Stipendio", 1500.0, ""]
      sheet.row(4).replace ["02/08/2024", "Prelievo", "", "50,00"]
      File.open(path, "wb") { |file| book.write(file) }

      rows = PortfolioPerformanceApi::FinecoXls.parse(path, skip_lines: 0)
      assert_equal 2, rows.size
      assert_equal Date.new(2024, 8, 1), rows[0].date
      assert_equal 150_000, rows[0].amount_cents
      assert_equal :DEPOSIT, rows[0].type
      assert_equal :REMOVAL, rows[1].type
      assert_equal 5_000, rows[1].amount_cents
    end
  end

  def test_store_roundtrip_appends_transactions
    Dir.mktmpdir do |dir|
      path = File.join(dir, "wallet.portfolio")
      File.binwrite(path, encrypted_protobuf)

      loaded = PortfolioPerformanceApi::PortfolioStore.load(path, password: "secret")
      account = PortfolioPerformanceApi::FinecoImport.find_account(loaded.client, "Conto corrente")
      before = loaded.client.transactions.size
      row = PortfolioPerformanceApi::FinecoXls::Row.new(
        date: Date.new(2026, 1, 2),
        description: "Fineco import",
        amount_cents: 9_900,
        type: :REMOVAL
      )
      PortfolioPerformanceApi::FinecoImport.append!(loaded.client, account, [row])
      PortfolioPerformanceApi::PortfolioStore.save(loaded)

      reloaded = PortfolioPerformanceApi::PortfolioStore.load(path, password: "secret")
      assert_equal before + 1, reloaded.client.transactions.size
      imported = reloaded.client.transactions.last
      assert_equal :REMOVAL, imported.type
      assert_equal 9_900, imported.amount
      assert_equal "Fineco import", imported.note
      assert_equal "acc-cash", imported.account
    end
  end

  def test_encrypted_save_writes_data_entry_pp_reads
    Dir.mktmpdir do |dir|
      path = File.join(dir, "wallet.portfolio")
      File.binwrite(
        path,
        PortfolioPerformanceApi::Decryptor.encrypt(
          zip_protobuf(entry: "data"),
          "secret",
          aes256: true,
          content_type: 2,
          version: 70
        )
      )

      loaded = PortfolioPerformanceApi::PortfolioStore.load(path, password: "secret")
      account = PortfolioPerformanceApi::FinecoImport.find_account(loaded.client, "Conto corrente")
      PortfolioPerformanceApi::FinecoImport.append!(
        loaded.client,
        account,
        [
          PortfolioPerformanceApi::FinecoXls::Row.new(
            date: Date.new(2026, 8, 15),
            description: "VISA DEBIT CRYPTO TAX - KOIN...",
            amount_cents: 9_900,
            type: :REMOVAL
          )
        ]
      )
      PortfolioPerformanceApi::PortfolioStore.save(loaded)

      payload = PortfolioPerformanceApi::Decryptor.decrypt(File.binread(path), "secret")
      names = []
      first = nil
      Zip::File.open_buffer(StringIO.new(payload.zip_bytes)) do |zip|
        zip.each do |entry|
          next if entry.directory?

          names << entry.name
          first ||= entry.get_input_stream.read
        end
      end

      assert_equal ["data"], names
      client = PortfolioPerformanceApi::Proto::PClient.decode(
        PortfolioPerformanceApi::FileReader.strip_proto_magic(first)
      )
      imported = client.transactions.last
      assert_equal :REMOVAL, imported.type
      assert_equal 9_900, imported.amount
      assert_equal "VISA DEBIT CRYPTO TAX - KOIN...", imported.note
      assert_equal "acc-cash", imported.account
    end
  end
end
