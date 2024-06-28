require 'sinatra'
require 'telegram/bot'
require 'dotenv/load'
require "google/cloud/firestore"
require "pry"
require 'date'


TOKEN = ENV["TELEGRAM_TOKEN"]
DEFAULT_CURRENCY = ENV["DEFAULT_CURRENCY"]
set :bind, "0.0.0.0"
port = ENV["PORT"] || "8080"
set :port, port

bot = Telegram::Bot::Client.new(TOKEN)

# Set up Firestore
firestore = Google::Cloud::Firestore.new project_id: 'telegram-bot-427111'

# Define valid categories
VALID_CATEGORIES = [
  '🏠 Housing and utilities', '🛒 Groceries', '🍔 Outside food', '👖 Clothes and 👟 shoes',
  '🪥 Household', '🚌 Commuting', '🍿 Entertainment'
]

get "/" do
  "Hello!"
end

get "/webhook" do
  "Webhook 200"
end

post '/webhook' do
  # request.body.rewind
  update = JSON.parse(request.body.read)
  puts JSON.pretty_generate(update)

  if update['message'] && update['message']['text']
    ## Main Message received
    message = update['message']['text']

    ## From Chat ID
    chat_id = update['message']['chat']['id'].to_s

    ## From User
    user_id = update['message']['from']['id'].to_s
    first_name = update['message']['from']['first_name']

    # Ensure chat and user exist in Firestore
    chat_ref = firestore.doc("chats/#{chat_id}")
    chat_ref.set({ chat_id: chat_id }, merge: true)

    user_ref = firestore.doc("users/#{user_id}")
    user_ref.set({ user_id: user_id, first_name: first_name }, merge: true)

    chat_users_ref = firestore.doc("chats/#{chat_id}/users/#{user_id}")
    chat_users_ref.set({ user_id: user_id }, merge: true)

    case message

    # Case: /start for all new bot chats
    when '/start'
      bot.api.send_message(chat_id: chat_id, text: "Hello, I am your expense tracker bot. Please add expenses in the format: '[Expense Item] [Amount] [currency (optional)]'. For example, 'Lunch 20 USD' or 'Coffee 5'. Use '+' before the amount to indicate income, e.g., 'Salary +2000 USD'.")
    when '/stats'
      n = DateTime.now
      start_of_month = Date.new(n.year, n.month)
      end_of_month = Date.new(n.year, n.month, -1)

      expenses = firestore.collection("chats/#{chat_id}/transactions")
                         .where("transaction_type", "==", "expense")
                         .where("created_at", ">=", start_of_month.to_time.utc.iso8601)
                         .where("created_at", "<=", end_of_month.to_time.utc.iso8601)
                         .get

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

      if total_expense > 0
        category_percentages = category_totals.map do |category, amount|
          percentage = (amount / total_expense) * 100
          "#{category}: #{'%.2f' % percentage}%"
        end.join("\n")
      
        user_expenses = user_totals.map do |user_id, amount|
          "#{user_names[user_id]}: $#{'%.2f' % amount}"
        end.join("\n")

        split_amount = total_expense / user_totals.keys.size

        response_text = "Total expenses for the month of #{Date.today.strftime("%B")}: <b>$#{'%.2f' % total_expense}</b>\n\n" \
                        "<b>Breakdown by category:</b>\n#{category_percentages}\n\n" \
                        "<b>Expenses by user:</b>\n#{user_expenses}\n\n" \
                        "Each person should pay: <b>$#{'%.2f' % split_amount}</b>\n\n" \
      else
        response_text = "No expenses recorded for the current month."
      end

      bot.api.send_message(chat_id: chat_id, text: response_text, parse_mode: "html")
    else
      if message.match(/^(.+?)\s+([+-]?\d+(\.\d{1,2})?)\s*(\w{3})?$/)
        item = $1.strip
        amount = $2.to_f
        is_income = $2.start_with?('+')
        amount = amount.abs if is_income # Ensure amount is positive for income
        currency = $4 ? $4.upcase : DEFAULT_CURRENCY

        # Store pending expense or income in Firestore
        firestore.collection("chats/#{chat_id}/pending_expenses").doc(user_id).set({
          created_at: Time.now.utc.iso8601,
          name: item,
          amount: amount,
          user_id: user_id,
          user_first_name: first_name,
          currency: currency,
          transaction_type: is_income ? 'income' : 'expense'
        })

        unless is_income
          # Send inline keyboard for category selection for expenses only
          kb = VALID_CATEGORIES.map do |category|
            Telegram::Bot::Types::InlineKeyboardButton.new(text: category, callback_data: "category_#{category}")
          end.each_slice(2).to_a

          bot.api.send_message(
            chat_id: chat_id,
            text: "Please select a category for the expense:",
            reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: kb)
          )
        else
          # Directly store the income transaction and inform the user
          pending_expense_ref = firestore.doc("chats/#{chat_id}/pending_expenses/#{user_id}")
          expense_data = pending_expense_ref.get.data
          
          firestore.collection("chats/#{chat_id}/transactions").add(expense_data)
          pending_expense_ref.delete

          bot.api.send_message(chat_id: chat_id, text: "<b>#{expense_data[:user_first_name]}</b> added income: #{expense_data[:name]}  $#{expense_data[:amount]} #{expense_data[:currency]}", parse_mode: "html")
        end
      else
        bot.api.send_message(chat_id: chat_id, text: "I don't understand that format. Please add transactions in the format: '[Item] [Amount] [currency (optional)]'. For example, 'Lunch 20 USD' or 'Salary +2000 USD'.")
      end
    end
  elsif update['callback_query']
    callback_data = update['callback_query']['data']
    chat_id = update['callback_query']['message']['chat']['id'].to_s
    user_id = update['callback_query']['from']['id'].to_s

    if callback_data.start_with?('category_')
      category = callback_data.sub('category_', '')

      if VALID_CATEGORIES.include?(category)
        # Retrieve pending expense from Firestore
        pending_expense_ref = firestore.doc("chats/#{chat_id}/pending_expenses/#{user_id}")

        pending_expense_ref.set({ category: category }, merge: true)
        expense_data = pending_expense_ref.get.data

        # Store the expense in transactions
        firestore.collection("chats/#{chat_id}/transactions").add(expense_data)

        # Delete the pending expense
        pending_expense_ref.delete

        bot.api.send_message(chat_id: chat_id, text: "<b>#{expense_data[:user_first_name]}</b> added expense: <b>#{expense_data[:name]}</b> <b>#{expense_data[:amount]} #{expense_data[:currency]}</b> in Category <b>#{expense_data[:category]}</b>", parse_mode: "html")
      else
        bot.api.send_message(chat_id: chat_id, text: "Invalid category selected.")
      end
    end
  end

  status 200
end
