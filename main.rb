require 'sinatra'
require 'telegram/bot'
require 'dotenv/load'

TOKEN = ENV["TELEGRAM_TOKEN"]
DEFAULT_CURRENCY = ENV["DEFAULT_CURRENCY"]
set :bind, "0.0.0.0"
port = ENV["PORT"] || "8080"
set :port, port

bot = Telegram::Bot::Client.new(TOKEN)

get "/" do
    "Hello!"
end

get "/webhook" do
  "Webhook 200"
end
  

post '/webhook' do
  #request.body.rewind
  update = JSON.parse(request.body.read)
  puts update

  if update['message'] && update['message']['text']
    message = update['message']['text']
    chat_id = update['message']['chat']['id']

    case message

    # Case: /start for all new bot chats
    # 1. Check if it's a new expense
    # 2. Check if it's an edited message
    # 3. Check if it's a summary request


    when '/start'
      bot.send_message(chat_id: chat_id, text: "Hello, I am your expense tracker bot. Please add expenses in the format: '[Expense Item] [Amount] [currency (optional)]'. For example, 'Lunch 20 USD' or 'Coffee 5'.")
    else
      if message.match(/^(.+?)\s+(\d+(\.\d{1,2})?)\s*(\w{3})?$/)
        item = $1.strip
        amount = $2.to_f
        currency = $4 ? $4.upcase : DEFAULT_CURRENCY

        # Here you would add logic to store the expense in a database or file
        bot.send_message(chat_id: chat_id, text: "Added expense: #{item} - $#{amount} #{currency}")
      else
        bot.send_message(chat_id: chat_id, text: "I don't understand that format. Please add expenses in the format: '[Expense Item] [Amount] [currency (optional)]'. For example, 'Lunch 20 USD' or 'Coffee 5'.")
      end
    end
  end

  status 200
end