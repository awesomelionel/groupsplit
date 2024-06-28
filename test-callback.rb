require 'sinatra'
require 'telegram/bot'
require 'dotenv/load'
require "google/cloud/firestore"

TOKEN = ENV["TELEGRAM_TOKEN"]
DEFAULT_CURRENCY = ENV["DEFAULT_CURRENCY"]
set :bind, "0.0.0.0"
port = ENV["PORT"] || "8080"
set :port, port

bot = Telegram::Bot::Client.new(TOKEN)

VALID_CATEGORIES = [
  '🏠 Housing and utilities', '🛒 Groceries', '🍔 Outside food', '👖 Clothes and 👟 shoes',
  '🪥 Household', '🚌 Commuting', '🍿 Entertainment'
]

post '/webhook' do
  update = JSON.parse(request.body.read)

  if update['message'] && update['message']['text']
    ##Main Message received
    message = update['message']['text']
    puts message

    ##From Chat ID
    chat_id = update['message']['chat']['id'].to_s
    puts chat_id

    ##From User
    user_id = update['message']['from']['id'].to_s
    first_name = update['message']['from']['first_name']
    puts user_id + " " + first_name

    case message
    when '/start'
        bot.api.send_message(chat_id: chat_id, text: "Hello, I am your expense tracker bot. Please add expenses in the format: '[Expense Item] [Amount] [currency (optional)]'. For example, 'Lunch 20 USD' or 'Coffee 5'. Use '+' before the amount to indicate income, e.g., 'Salary +2000 USD'.")
    else
      if message.match(/^(.+?)\s+([+-]?\d+(\.\d{1,2})?)\s*(\w{3})?$/)
        item = $1.strip
        puts item
        amount = $2.to_f
        puts amount
        is_income = $2.start_with?('+')
        amount = amount.abs if is_income # Ensure amount is positive for income
        puts amount
        currency = $4 ? $4.upcase : DEFAULT_CURRENCY
        puts currency
            # Send inline keyboard for category selection

          # Create inline keyboard for category selection
          kb = VALID_CATEGORIES.map do |category|
            Telegram::Bot::Types::InlineKeyboardButton.new(text: category, callback_data: "category_#{category}")
          end.each_slice(2).to_a
  
          # Send inline keyboard for category selection
          #logger.info "Sending inline keyboard for category selection"
          bot.api.send_message(
            chat_id: chat_id,
            text: "Please select a category for the expense:",
            reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: kb)
          )
        
      else
        bot.api.send_message(chat_id: chat_id, text: "I don't understand that format. Please add transactions in the format: '[Item] [Amount] [currency (optional)]'. For example, 'Lunch 20 USD' or 'Salary +2000 USD'.")
      end
    end
  elsif update['callback_query']
    callback_data = update['callback_query']['data']
    chat_id = update['callback_query']['message']['chat']['id'].to_s
    user_id = update['callback_query']['from']['id'].to_s
    #Do something
  end
end