require 'bitcoin'
require 'open-uri'
require 'http'
require 'json'
Bitcoin.network = :testnet
include ::Bitcoin::Builder

module Wallet
  extend self

  SATOSHI_PER_BITCOIN = 100_000_000 # (1 BTC = 100,000,000 Satoshi)

  # Константы для расчета комиссии 
  TRANSACTION_SIZE = 10 # Размер самой транзакции
  INPUT_TRANSACTION_SIZE = 148 # Размер входной транзакции
  OUTPUT_TRANSACTION_SIZE = 34 # Размер выходной транзакции

  def wallet_key(wallet_name)
    base58 = File.read("wallets/#{wallet_name}.base58")
    
    Bitcoin::Key.from_base58(base58)
  end

  def utxos(address)
    url = "https://blockstream.info/testnet/api/address/#{address}/utxo"

    return JSON.parse(URI.open(url).string) rescue []
  end

  def fetch_tx(txid)
    url = "https://blockstream.info/testnet/api/tx/#{txid}/hex"

    hex_tx = URI.open(url).string
    binary = [hex_tx].pack("H*")
    
    Bitcoin::Protocol::Tx.new(binary)
  end


  def calculate_balance(address)
    confirmed = 0
    unconfirmed = 0
    self.utxos(address).each do |utxo| 
      is_confirmed = utxo["status"]["confirmed"] rescue false
      confirmed += utxo["value"] if is_confirmed
      unconfirmed += utxo["value"] unless is_confirmed
    end
    
    return {
      "confirmed": confirmed,
      "unconfirmed": unconfirmed,
      "total": unconfirmed + confirmed
    }
  end

  def get_current_fee
    url = "https://blockstream.info/testnet/api/mempool"

    return JSON.parse(URI.open(url).string)["fee_histogram"][0][0] * 1.0 rescue 1.0
  end

  def make_transaction_v2(source_base_58, destination_address, amount)
    return puts "ERROR: Destination address not specified" unless destination_address
    return puts "ERROR: Base58_key not specified" unless source_base_58
    return puts "ERROR: Wrong amount value" if !amount || amount.to_f <= 0
    
    source_account_key = Bitcoin::Key.from_base58(source_base_58) rescue nil
    return puts "ERROR: Wrong base58_key" unless source_account_key
    
    available_utxos = self.utxos(source_account_key.addr).sort{|a,b| b["value"] - a["value"]} # Чем меньше входов - тем дешевле, сортируем по сумме
    
    fee_rate = self.get_current_fee
    payment_amount = amount.to_f * SATOSHI_PER_BITCOIN

    withdrawal_amount = 0
    total_fee = (TRANSACTION_SIZE + OUTPUT_TRANSACTION_SIZE) * fee_rate # Начальная комиссия - размер транзакции + размер одной выходной транзакции(на счет получателя)
    unspent = payment_amount + total_fee

    relevant_utxos = []
    available_utxos.each do |utxo|
      utxo_tx = self.fetch_tx(utxo["txid"])
      vout = utxo["vout"]
      tx_value = utxo_tx.out[vout].value
      
      unspent += INPUT_TRANSACTION_SIZE * fee_rate # Прибавляем комиссию за input к минимальной сумме
      total_fee += INPUT_TRANSACTION_SIZE * fee_rate

      unspent -= tx_value
      withdrawal_amount += tx_value

      relevant_utxos << {
        "tx": utxo_tx,
        "vout": vout
      }

      if unspent <= 0
        # Если есть остаток - считаем + 1 выход в комиссию
        if (withdrawal_amount - total_fee - payment_amount) > 0
          unspent += OUTPUT_TRANSACTION_SIZE * fee_rate # Прибавляем unspent чтобы добрать транзакций, если с учетом нового выхода превышаем сумму отобранных входных транзакций
          total_fee += OUTPUT_TRANSACTION_SIZE * fee_rate
        end

        break if unspent <= 0
      end
    end
    
    if unspent > 0
      puts "ERROR: Not have enough coin! requested(amount, fee) #{(payment_amount.to_f/SATOSHI_PER_BITCOIN).round(10)}(#{(payment_amount.to_f/SATOSHI_PER_BITCOIN).round(10)} btc, #{total_fee.to_i} satoshi), have #{(withdrawal_amount.to_f/SATOSHI_PER_BITCOIN).round(10)}"
      return
    end

    puts "INFO: Total input btc amount, transactions amount: #{withdrawal_amount}, #{relevant_utxos.length}"
    puts "INFO: Calculated fee: #{total_fee}"
    puts "INFO: Payment amount: #{payment_amount}"

    # Собираем транзакцию

    tx = Bitcoin::Protocol::Tx.new

    relevant_utxos.each{|utxo| tx.add_in(Bitcoin::Protocol::TxIn.from_hex_hash(utxo[:tx].hash, utxo[:vout])) }

    tx.add_out(Bitcoin::Protocol::TxOut.value_to_address(payment_amount.to_i, destination_address))
    # Возвращаем лишние монеты обратно (не учитывая комиссию)
    if withdrawal_amount > (payment_amount + total_fee)
      tx.add_out(Bitcoin::P::TxOut.value_to_address((withdrawal_amount - payment_amount - total_fee).to_i, source_account_key.addr))
    end

    # Подписываем транзакции
    all_verified = true
    relevant_utxos.each.with_index do |utxo, index|
      sig = Bitcoin.sign_data(source_account_key.key, tx.signature_hash_for_input(index, utxo[:tx]))
      tx.in[index].add_signature_pubkey_script(sig, source_account_key.pub)

      unless tx.verify_input_signature(index, utxo[:tx])
        all_verified = false
        break
      end
    end

    # Отправляем транзакцию, если подпись удалась
    if all_verified
      hex = tx.to_payload.unpack("H*")[0]

      response = HTTP.post("https://blockstream.info/testnet/api/tx", :body => hex)
      if response.status == 200
        puts "INFO: TRANSACTION CREATED TXID: #{response.body.to_s}"
      else
        puts "ERROR: TRANSACTION CREATION FAILED: #{response.body.to_s}"
      end
    else
      puts "ERROR: VERIFICATION FAILED"
    end
  end

  def balance(address)
    return puts "ERROR: Address not specified" unless address

    result = self.calculate_balance(address)
    puts "=============Address balance========"
    puts "Confirmed: #{result[:confirmed].to_f / SATOSHI_PER_BITCOIN}"
    puts "Unconfirmed: #{result[:unconfirmed].to_f / SATOSHI_PER_BITCOIN}"
    puts "Total: #{result[:total].to_f / SATOSHI_PER_BITCOIN}"
    puts "===================================="
  end

  def generate_wallet(wallet_name)
    return puts "ERROR: Wallet name not specified" unless wallet_name

    Dir.mkdir 'wallets' rescue nil

    key = ::Bitcoin::Key.generate
    File.write("wallets/" + wallet_name + ".base58", key.to_base58)

    puts "============================================="
    puts "Wallet name #{wallet_name}"
    puts "Private Key: #{key.priv}"
    puts "Your Address: #{key.addr}"
    puts "Base58: #{key.to_base58}"
    puts "============================================="
  end

  def read_wallet(wallet_name)
    return puts "ERROR: Wallet name not specified" unless wallet_name

      
    key = self.wallet_key(wallet_name)

    puts "============================================="
    puts "Wallet name #{wallet_name}"
    puts "Private Key: #{key.priv}"
    puts "Your Address: #{key.addr}"
    puts "Base58: #{key.to_base58}"
    puts "============================================="
  end
end

class Console
  def initialize(command, args)
    case command
    when "transaction"
      ::Wallet.make_transaction_v2(args[0], args[1], args[2])
    when "generate"
      ::Wallet.generate_wallet(args[0])
    when "read"
      ::Wallet.read_wallet(args[0])
    when "balance"
      ::Wallet.balance(args[0])
    else
      puts "Simple Bitcoin Testnet Wallet App"
      puts "\nCommands:"
      puts "\twallet.rb transaction base58_key destination_address amount(in btc) - Make transaction between addresses"
      puts "\twallet.rb generate wallet_name - Generate new Bitcoin Testnet wallet"
      puts "\twallet.rb read wallet_name - Read wallet information (private key, base58 key, address)"
      puts "\twallet.rb balance address - Show address balance"
    end
  end
end

Console.new(ARGV[0], ARGV[1..-1])