require 'sinatra'
require 'telegram/bot'
require 'dotenv/load'
require 'google/cloud/firestore'
require 'pry'
require 'date'
require 'active_support'
require 'active_support/core_ext/time'

set :bind, "0.0.0.0"
port = ENV["PORT"] || "8080"
set :port, port

class ExpenseBot
  TOKEN = ENV["TELEGRAM_TOKEN"]
  DEFAULT_CURRENCY = ENV["DEFAULT_CURRENCY"]
  BOT_USERNAME = ENV["BOT_USERNAME"]
  SINGAPORE_TZ = ActiveSupport::TimeZone.new("Singapore")
  VALID_CATEGORIES = [
    '🏠 Housing and utilities', '🛒 Groceries', '🍔 Outside food', '👖 Clothes and 👟 shoes',
    '🪥 Household', '🚌 Commuting', '🍿 Entertainment'
  ]

  def initialize
    @bot = Telegram::Bot::Client.new(TOKEN)
    @firestore = Google::Cloud::Firestore.new project_id: ENV['GOOGLE_PROJECT_ID']
  end

  def handle_webhook(update)

    if update['message'] && update['message']['text']
      handle_message(update['message'])
    elsif update['callback_query']
      handle_callback(update['callback_query'])
    end
  end

  private

  def handle_message(message)
    text = message['text']
    chat_id = message['chat']['id'].to_s
    user_id = message['from']['id'].to_s
    first_name = message['from']['first_name']

    ensure_chat_and_user(chat_id, user_id, first_name)

    case text
    when '/start'
      send_welcome_message(chat_id)
    when '/stats'
      send_stats(chat_id)
    else
      handle_expense_message(text, chat_id, user_id, first_name) if text.start_with?("@#{BOT_USERNAME}")
    end
  end

  def handle_expense_message(text, chat_id, user_id, first_name)
    if text.match(/^@#{BOT_USERNAME}\s+(.+?)\s+([+-]?\d+(\.\d{1,2})?)\s*(\w{3})?$/)
      item, amount, currency = parse_expense_message(text)
      is_income = amount.start_with?('+')
      amount = amount.to_f.abs

      store_pending_expense(chat_id, user_id, first_name, item, amount, currency, is_income)

      unless is_income
        send_category_keyboard(chat_id)
      else
        store_income(chat_id, user_id)
      end
    else
      send_invalid_format_message(chat_id)
    end
  end

  def parse_expense_message(text)
    match_data = text.match(/^@#{BOT_USERNAME}\s+(.+?)\s+([+-]?\d+(\.\d{1,2})?)\s*(\w{3})?$/)
    item = match_data[1].strip
    amount = match_data[2]
    currency = match_data[4] ? match_data[4].upcase : DEFAULT_CURRENCY
    [item, amount, currency]
  end

  def store_pending_expense(chat_id, user_id, first_name, item, amount, currency, is_income)
    @firestore.collection("chats/#{chat_id}/pending_expenses").doc(user_id).set({
      created_at: Time.now.utc.iso8601,
      name: item,
      amount: amount,
      user_id: user_id,
      user_first_name: first_name,
      currency: currency,
      transaction_type: is_income ? 'income' : 'expense'
    })
  end

  def send_category_keyboard(chat_id)
    kb = VALID_CATEGORIES.map do |category|
      Telegram::Bot::Types::InlineKeyboardButton.new(text: category, callback_data: "category_#{category}")
    end.each_slice(2).to_a

    @bot.api.send_message(
      chat_id: chat_id,
      text: "Please select a category for the expense:",
      reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: kb)
    )
  end

  def store_income(chat_id, user_id)
    pending_expense_ref = @firestore.doc("chats/#{chat_id}/pending_expenses/#{user_id}")
    expense_data = pending_expense_ref.get.data

    @firestore.collection("chats/#{chat_id}/transactions").add(expense_data)
    pending_expense_ref.delete

    @bot.api.send_message(chat_id: chat_id, text: "<b>#{expense_data[:user_first_name]}</b> added income: #{expense_data[:name]}  $#{expense_data[:amount]} #{expense_data[:currency]}", parse_mode: "html")
  end

  def send_invalid_format_message(chat_id)
    @bot.api.send_message(chat_id: chat_id, text: "I don't understand that format. Please add transactions in the format: '@#{BOT_USERNAME} [Item] [Amount] [currency (optional)]'. For example, '@#{BOT_USERNAME} Lunch 20 USD' or '@#{BOT_USERNAME} Salary +2000 USD'.")
  end

  def handle_callback(callback_query)
    callback_data = callback_query['data']
    chat_id = callback_query['message']['chat']['id'].to_s
    user_id = callback_query['from']['id'].to_s

    if callback_data.start_with?('category_')
      handle_category_selection(callback_data, chat_id, user_id)
    end
  end

  def handle_category_selection(callback_data, chat_id, user_id)
    category = callback_data.sub('category_', '')

    if VALID_CATEGORIES.include?(category)
      pending_expense_ref = @firestore.doc("chats/#{chat_id}/pending_expenses/#{user_id}")
      pending_expense_ref.set({ category: category }, merge: true)
      expense_data = pending_expense_ref.get.data

      @firestore.collection("chats/#{chat_id}/transactions").add(expense_data)
      pending_expense_ref.delete

      @bot.api.send_message(chat_id: chat_id, text: "<b>#{expense_data[:user_first_name]}</b> added expense: <b>#{expense_data[:name]}</b> <b>#{expense_data[:amount]} #{expense_data[:currency]}</b> in Category <b>#{expense_data[:category]}</b>", parse_mode: "html")
    else
      @bot.api.send_message(chat_id: chat_id, text: "Invalid category selected.")
    end
  end

  def send_welcome_message(chat_id)
    @bot.api.send_message(chat_id: chat_id, text: "Hello, I am your expense tracker bot. Please add transactions in the format: '@#{BOT_USERNAME} [Item] [Amount] [currency (optional)]'. For example, '@#{BOT_USERNAME} Lunch 20 USD' or '@#{BOT_USERNAME} Salary +2000 USD'.")
  end

  def send_stats(chat_id)
    current_time = Time.now.in_time_zone(SINGAPORE_TZ)
    start_of_month = current_time.beginning_of_month.utc.iso8601
    end_of_month = current_time.end_of_month.utc.iso8601

    expenses = @firestore.collection("chats/#{chat_id}/transactions")
                         .where("transaction_type", "==", "expense")
                         .where("created_at", ">=", start_of_month)
                         .where("created_at", "<=", end_of_month)
                         .get

    total_expense, category_totals, user_totals, user_names = calculate_expenses(expenses)

    if total_expense > 0
      response_text = build_stats_response(total_expense, category_totals, user_totals, user_names)
    else
      response_text = "No expenses recorded for the current month."
    end

    @bot.api.send_message(chat_id: chat_id, text: response_text, parse_mode: "html")
  end

  def calculate_expenses(expenses)
    total_expense = 0
    category_totals = Hash.new(0)
    user_totals = Hash.new(0)
    user_names = {}

    expenses.each do |expense|
      data = expense.data
      amount = data[:amount].to_f
      category = data[:category]
      user_id = data[:user_id]
      user_name = data[:user_first_name]

      total_expense += amount
      category_totals[category] += amount
      user_totals[user_id] += amount
      user_names[user_id] = user_name
    end

    [total_expense, category_totals, user_totals, user_names]
  end

  def build_stats_response(total_expense, category_totals, user_totals, user_names)
    category_percentages = category_totals.map do |category, amount|
      percentage = (amount / total_expense) * 100
      "#{category}: #{'%.2f' % percentage}%"
    end.join("\n")

    user_expenses = user_totals.map do |user_id, amount|
      "#{user_names[user_id]}: $#{'%.2f' % amount}"
    end.join("\n")

    split_amount = total_expense / user_totals.keys.size

    "Total expenses for the month of #{Date.today.strftime("%B")}: <b>$#{'%.2f' % total_expense}</b>\n\n" \
    "<b>Breakdown by category:</b>\n#{category_percentages}\n\n" \
    "<b>Expenses by user:</b>\n#{user_expenses}\n\n" \
    "Each person should pay: <b>$#{'%.2f' % split_amount}</b>\n\n"
  end

  def ensure_chat_and_user(chat_id, user_id, first_name)
    chat_ref = @firestore.doc("chats/#{chat_id}")
    chat_ref.set({ chat_id: chat_id }, merge: true)

    user_ref = @firestore.doc("users/#{user_id}")
    user_ref.set({ user_id: user_id, first_name: first_name }, merge: true)

    chat_users_ref = @firestore.doc("chats/#{chat_id}/users/#{user_id}")
    chat_users_ref.set({ user_id: user_id }, merge: true)
  end
end
# Initialize the bot
expense_bot = ExpenseBot.new

post '/webhook' do
  update = JSON.parse(request.body.read)
  puts JSON.pretty_generate(update)

  expense_bot.handle_webhook(update)
  status 200
end