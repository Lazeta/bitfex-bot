#!/usr/bin/env ruby

class String
  # colorization
  def colorize(color_code)
    "\e[#{color_code}m#{self}\e[0m"
  end

  def red
    colorize(31)
  end

  def green
    colorize(32)
  end

  def yellow
    colorize(33)
  end

  def blue
    colorize(34)
  end

  def pink
    colorize(35)
  end

  def light_blue
    colorize(36)
  end
end

module Enumerable
  # Calculates a sum from the elements.
  #
  #  payments.sum { |p| p.price * p.tax_rate }
  #  payments.sum(&:price)
  #
  # The latter is a shortcut for:
  #
  #  payments.inject(0) { |sum, p| sum + p.price }
  #
  # It can also calculate the sum without the use of a block.
  #
  #  [5, 15, 10].sum # => 30
  #  ['foo', 'bar'].sum # => "foobar"
  #  [[1, 2], [3, 1, 5]].sum => [1, 2, 3, 1, 5]
  #
  # The default sum of an empty list is zero. You can override this default:
  #
  #  [].sum(Payment.new(0)) { |i| i.amount } # => Payment.new(0)
  def sum(identity = nil, &block)
    if block_given?
      map(&block).sum(identity)
    else
      sum = identity ? inject(identity, :+) : inject(:+)
      sum || identity || 0
    end
  end
end

require "open-uri"
require "bitfex"

# Default Trading Pairs
TRADE_PAIRS = %w[
  BTC_RUR
  ETH_RUR
].freeze

class Bot
  # Run bot
  # @param email [String] user email
  # @param password [String] user password
  # @param pairs [Array<String>] list of pairs
  def initialize(email = ENV["EMAIL"], password = ENV["PASSWORD"], pairs = ENV["PAIRS"]&.split(",") || TRADE_PAIRS)
    @pairs = pairs
    auth(email, password)
    process_existing_pairs(pairs)

    create_new_orders(prepare_orders)
  end

  # Try to close existing orders in pairs
  # @param pairs [Array<String>] list of pairs
  def process_existing_pairs(pairs)
    pairs.each do |pair|
      log("[i] Process Existing #{pair}")
      process_existing(pair)
    end
  end

  # Place new orders by prices from wex or bitflip.cc
  # @param orders_data [Hash<Symbol,Hash>] list of orders data
  # Example:
  #   {
  #     "BTC_RUR" => {
  #       buy: [{ price: 100_000, amount: 1 }],
  #       sell: [{ price: 101_000, amount: 3 }]
  #     }
  #   }
  def create_new_orders(orders_data)
    orders_data.each do |(pair, orders)|
      log("[i] Processing #{pair}")
      ranges = {
        buy: 0.995..0.9999,
        sell: 1.0001..1.005
      }
      %i[buy sell].each do |operation|
        orders[operation].each do |order|
          begin
            amount = order[:amount]
            price = order[:price] * rand(ranges[operation])
            log("[i]   create_order(#{operation}, #{pair}, #{amount.round(8)}, #{price})")
            api.create_order(operation, pair, amount, price)
          rescue Bitfex::ApiError => e
            error("[E]   create_order error: #{e.message}")
          end
        end
      end
    end
  end

  private

  # @return [Bitfex::Api] instance of api
  def api
    @_api ||= Bitfex::Api.new(server_url: ENV["SERVER"] || "https://bitfex.trade")
  end

  def auth(email, password)
    api.auth(email, password)
  end

  def prepare_orders
    initial_balances = api.balances

    @pairs.each_with_object({}) do |pair, acc|
      log("[i] Prepare #{pair}")
      base, target = pair.split("_")

      acc[pair] = {
        buy: generate_orders(initial_balances, :buy, base, target),
        sell: generate_orders(initial_balances, :sell, base, target)
      }
    end
  end

  def generate_orders(initial_balances, operation, base, target, k = 1.0)
    currency = operation == :buy ? target : base
    opposite_operation = operation == :buy ? "sell" : "buy"

    orders_amount = rand(2..3)
    slots = @pairs.count { |p| p.include?(currency) }
    funds = initial_balances[currency] / slots.to_f
    initial = Array.new(orders_amount) do
      {
        price: price_for(base, target)[opposite_operation] * k,
        amount: rand
      }
    end
    initial_sum = initial.sum { |order| order[:amount] }
    initial.map do |order|
      order.merge(amount: order[:amount] / initial_sum * (funds * 0.99) / order[:price])
    end
  end

  def process_existing(pair)
    my_pair_orders = my_orders_for_pair(pair)

    if my_pair_orders.count.zero? # no orders
      warn("[i]   no orders, do nothing")
    elsif my_pair_orders.none? { |order| order["operation"] == "sell" } # only buy orders
      warn("[i]   only buy orders found, do nothing")
    elsif my_pair_orders.none? { |order| order["operation"] == "buy" } # only sell orders
      warn("[i]   only sell orders found, do nothing")
    else # buy and sell orders
      log("[i]   found buy and sell orders")
      # destroy all random orders
      operation, opposite_operation = %w[buy sell].shuffle
      close_my_orders(my_pair_orders, pair, operation, opposite_operation)
    end

    # destroy all my orders for pair (fetch new orders and destroy them all)
    my_orders_for_pair(pair).each { |order| api.delete_order(order["id"]) }
  rescue StandardError => e
    error("[E]  unknown error: #{e.message}")
  end

  def close_my_orders(orders, pair, operation, opposite_operation)
    orders.find_all { |order| order["operation"] == operation }.each { |order| api.delete_order(order["id"]) }

    total_amount = orders_total_amount(orders, opposite_operation)
    price = operation == "buy" ? max_price(orders, opposite_operation) : min_price(orders, opposite_operation)

    amount = closing_order_amount(operation, total_amount, price, pair)

    # make order which try to close all opposite orders
    log("[i]   create_order(#{operation}, #{pair}, #{amount.round(8)}, #{price})")
    api.create_order(operation, pair, amount, price)
  end

  def closing_order_amount(operation, total_amount, price, pair)
    balances = api.balances
    base, target = pair.split("_")
    return (balances[target] / price) if operation == "buy" && balances[target] < total_amount * price
    return balances[base] if operation == "sell" && balances[base] < total_amount
    total_amount
  end

  def max_price(orders, operation)
    orders.find_all { |order| order["operation"] == operation }.max_by { |order| order["price"] }["price"]
  end

  def min_price(orders, operation)
    orders.find_all { |order| order["operation"] == operation }.min_by { |order| order["price"] }["price"]
  end

  def orders_total_amount(orders, operation)
    orders.find_all { |order| order["operation"] == operation }.sum { |order| order["amount"] }
  end

  def my_orders_for_pair(pair)
    api.my_orders.find_all { |order| order["pair"] == pair }
  end

  def log(text)
    puts text.green
  end

  def warn(text)
    puts text.yellow
  end

  def error(text)
    puts text.red
  end

  def price_for(base, target)
    rates["#{base}_#{target}".downcase.gsub("dash", "dsh")]
  end

  def rates
    @_rates ||= begin
      pairs = @pairs.map(&:downcase).join("-").gsub("dash", "dsh")
      wex_rates = JSON.parse(open("https://wex.nz/api/3/ticker/#{pairs}?ignore_invalid=1").read)
      wex_rates.merge(bitflip_rates)
    end
  end

  def bitflip_rates
    api_data = JSON.parse(open("https://api.bitflip.cc/method/market.getRates").read)[1]
    ben_pairs = api_data.find_all { |ticker| ticker["pair"] =~ /BEN/ }
    ben_pairs.reduce({}) do |acc, item|
      pair_name = item["pair"].tr(":", "_").downcase.gsub("rub", "rur")
      acc.merge(
        pair_name => {
          "buy" => item["sell"],
          "sell" => item["buy"]
        }
      )
    end
  rescue StandardError
    {}
  end
end

Bot.new
