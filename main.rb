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
  DEFAULT_CATEGORIES = [
    '🏠 Housing and utilities', '🛒 Groceries', '🍔 Outside food', '👖 Clothes and 👟 shoes',
    '🪥 Household', '🚌 Commuting', '🍿 Entertainment'
  ]
  #VALID_TIMEZONES = ActiveSupport::TimeZone.all.map(&:name)
  VALID_CURRENCIES = ['🇺🇸 USD', '🇸🇬 SGD', '🇪🇺 EUR', '🇬🇧 GBP', '🇯🇵 JPY', '🇲🇾 MYR', '🇮🇩 IDR', '🇵🇭 PHP', '🇹🇭 THB', '🇰🇷 KRW']


  def initialize
    @bot = Telegram::Bot::Client.new(TOKEN)
    @firestore = Google::Cloud::Firestore.new project_id: ENV['GOOGLE_PROJECT_ID']
  end

  def is_private_chat?(message)
    message['chat']['type'] == 'private'
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

    ## Edit Expense
    if message['reply_to_message']
      original_message = message['reply_to_message']['text']
      if is_private_chat?(message)
        if original_message.match(/^(.+?)\s+\$?([+-]?\d+(\.\d{1,2})?)\s*(\w{3})?$/)
          edit_expense(original_message, text, chat_id, user_id)
          return
        end
      else
        if original_message.match(/^@#{BOT_USERNAME}\s+(.+?)\s+\$?([+-]?\d+(\.\d{1,2})?)\s*(\w{3})?$/)
          edit_expense(original_message, text, chat_id, user_id, is_group_chat: true)
          return
        end
      end
    end

    if is_private_chat?(message)
      message['chat']['type'] == 'private'
    end


    ## Category Creation
    if expecting_new_category?(chat_id)
      handle_category_creation(message)
    else
      case text
      when '/start'
        send_welcome_message(chat_id)
      when '/help'
        #TODO
        send_detailed_help_guide(chat_id)
      when '/stats'
        send_stats(chat_id)
      when '/settings'
        send_settings_options(chat_id)
      else
        if is_private_chat?(message)
          handle_expense_message(text, chat_id, user_id, first_name)
        elsif text.start_with?("@#{BOT_USERNAME}")
          #if true, then strip the bot's username from the message
          handle_expense_message(text.sub("@#{BOT_USERNAME}", "").strip, chat_id, user_id, first_name)
        end
      end
    end
  end

  def handle_expense_message(text, chat_id, user_id, first_name)
    if text.match(/^(.+?)\s+\$?([+-]?\d+(\.\d{1,2})?)\s*(\w{3})?$/)
      item, amount, currency = parse_expense_message(text, chat_id)
      is_income = amount.start_with?('+')
      amount = amount.to_f.abs

      # Try to find a previous expense with the same item name
      previous_category = find_previous_category(chat_id, item)

      store_pending_expense(chat_id, user_id, first_name, item, amount, currency, is_income)

      if previous_category && !is_income
        # If a previous category is found, store the expense with this category
        store_expense_with_category(chat_id, user_id, previous_category)
      elsif !is_income
        # Otherwise, prompt the user to select a category
        send_category_keyboard(chat_id)
      else
        store_income(chat_id, user_id)
      end
    else
      send_invalid_format_message(chat_id)
    end
  end

  def find_previous_category(chat_id, item)
    transactions = @firestore.collection("chats/#{chat_id}/transactions")
                     .where(:name, :==, item.downcase)
                     .order(:created_at, :desc)
                     .get
  
    transactions.each do |transaction|
      if transaction[:category]
        return transaction[:category]
      end
    end
  
    nil
  end
  
  def store_expense_with_category(chat_id, user_id, category)
    pending_expense_ref = @firestore.doc("chats/#{chat_id}/pending_expenses/#{user_id}")
    expense_data = pending_expense_ref.get.data
    
    # Ensure the hash is mutable
    mutable_expense_data = expense_data.dup.transform_keys(&:to_sym)
  
    mutable_expense_data[:category] = category
  
    @firestore.collection("chats/#{chat_id}/transactions").add(mutable_expense_data)
    pending_expense_ref.delete
  
    @bot.api.send_message(chat_id: chat_id, text: "<b>#{mutable_expense_data[:user_first_name]}</b> added expense: <b>#{mutable_expense_data[:name]}</b> <b>#{mutable_expense_data[:amount]} #{mutable_expense_data[:currency]}</b> in Category <b>#{category}</b>", parse_mode: "html")
  end 

  def parse_expense_message(text, chat_id)
    match_data = text.match(/^(.+?)\s+\$?([+-]?\d+(\.\d{1,2})?)\s*(\w{3})?$/)
    item = match_data[1].strip
    amount = match_data[2]
    currency = match_data[4] ? match_data[4].upcase : fetch_default_currency(chat_id)
    [item, amount, currency]
  end

  def fetch_default_currency(chat_id)
    chat_data = @firestore.doc("chats/#{chat_id}").get.data
    chat_data[:default_currency] || DEFAULT_CURRENCY
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
    chat_doc = @firestore.doc("chats/#{chat_id}")
    chat_data = chat_doc.get.data

    custom_categories = chat_data[:custom_categories] || []
    all_categories = DEFAULT_CATEGORIES + custom_categories

    kb = all_categories.map do |category|
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
    invalid_format_message_txt = "<b>Hello!</b>, I am your expense tracker bot.\n\n" \
                          "Please add transactions in the format: '@#{BOT_USERNAME} [Item] [Amount] [currency (optional)]'.\n\n" \
                          "For example, '@#{BOT_USERNAME} Lunch 20 SGD' or '@#{BOT_USERNAME} Starbucks Coffee 20'.\n\n" \
                          "You can even add Income with '@#{BOT_USERNAME} Salary +2000 SGD'.\n\n" \
                          "The Default currency is SGD. You can change it in the '/settings' command";

    @bot.api.send_message(chat_id: chat_id, text: invalid_format_message_txt, parse_mode: "html" )
  end

  def handle_callback(callback_query)
    callback_data = callback_query['data']
    chat_id = callback_query['message']['chat']['id'].to_s
    user_id = callback_query['from']['id'].to_s

    if callback_data.start_with?('category_')
      handle_category_selection(callback_data, chat_id, user_id)
    elsif callback_data.start_with?('settings_currency')
      send_currency_keyboard(chat_id)
    elsif callback_data.start_with?('currency_')
      handle_currency_selection(callback_data, chat_id)
    elsif callback_data.start_with?('settings_timezone')
      send_timezone_keyboard(chat_id)
    elsif callback_data.start_with?('timezone_')
      handle_timezone_selection(callback_data, chat_id)
    elsif callback_data.start_with?('settings_add_categories')
      prompt_for_custom_category(chat_id)
    end
  end

  def prompt_for_custom_category(chat_id)
    @bot.api.send_message(chat_id: chat_id, text: "Please send the name of the new category you'd like to add:")
    # Set the expecting_new_category flag to true
    chat_doc = @firestore.doc("chats/#{chat_id}")
    chat_doc.set({ expecting_new_category: true }, merge: true)
  end

  def expecting_new_category?(chat_id)
    # Check Firestore for a state flag indicating if the bot is expecting a new category
    chat_doc = @firestore.doc("chats/#{chat_id}")
    chat_data = chat_doc.get.data
  
    chat_data && chat_data[:expecting_new_category] == true
  end

  # Capture the new category from user
  def handle_category_creation(message)
    chat_id = message['chat']['id'].to_s
    new_category = message['text'].strip

    if new_category.empty?
      @bot.api.send_message(chat_id: chat_id, text: "Category name cannot be empty. Please try again.")
      return
    end

    add_custom_category(chat_id, new_category)
    @bot.api.send_message(chat_id: chat_id, text: "Category '#{new_category}' added successfully.")
  end

  # Add the custom category to Firestore
  def add_custom_category(chat_id, new_category)
    chat_doc = @firestore.doc("chats/#{chat_id}")
    chat_data = chat_doc.get.data || {}

    custom_categories = chat_data[:custom_categories] || []
    custom_categories << new_category unless custom_categories.include?(new_category)

    chat_doc.set({ custom_categories: custom_categories }, merge: true)
    chat_doc.set({ expecting_new_category: false }, merge: true)
  end

  def handle_category_selection(callback_data, chat_id, user_id)
    # Remove the 'category_' prefix to get the category name
    category = callback_data.sub('category_', '')

    # Retrieve custom categories from Firestore
    chat_doc = @firestore.doc("chats/#{chat_id}")
    chat_data = chat_doc.get.data
    custom_categories = chat_data[:custom_categories] || []

    # Combine default categories with custom categories
    all_categories = DEFAULT_CATEGORIES + custom_categories

    if all_categories.include?(category)
      # Reference to the pending expense document for the user
      pending_expense_ref = @firestore.doc("chats/#{chat_id}/pending_expenses/#{user_id}")
      # Update the pending expense with the selected category
      pending_expense_ref.set({ category: category }, merge: true)

      # Retrieve the updated expense data
      expense_data = pending_expense_ref.get.data

      # Add the expense data to the transactions collection
      @firestore.collection("chats/#{chat_id}/transactions").add(expense_data)

      # Delete the pending expense document
      pending_expense_ref.delete

      # Send a confirmation message to the user
      @bot.api.send_message(
        chat_id: chat_id,
        text: "<b>#{expense_data[:user_first_name]}</b> added expense: <b>#{expense_data[:name]}</b> <b>#{expense_data[:amount]} #{expense_data[:currency]}</b> in Category <b>#{expense_data[:category]}</b>",
        parse_mode: "html"
      )
    else
      # Handle the case where an invalid category was selected
      @bot.api.send_message(chat_id: chat_id, text: "Invalid category selected.")
    end
  end

  def handle_currency_selection(callback_data, chat_id)
    currency_with_emoji = callback_data.sub('currency_', '')
    # Strip the first two characters (emoji and space) and any trailing whitespace
    currency_code = currency_with_emoji[2..-1].strip

    if VALID_CURRENCIES.include?(currency_with_emoji)
      @firestore.doc("chats/#{chat_id}").set({ default_currency: currency_code }, merge: true)
      @bot.api.send_message(chat_id: chat_id, text: "Default currency updated to #{currency_with_emoji}.")
    else
      @bot.api.send_message(chat_id: chat_id, text: "Invalid currency selected.")
    end
  end

  def handle_timezone_selection(callback_data, chat_id)
    timezone = callback_data.sub('timezone_', '')

    if VALID_TIMEZONES.include?(timezone)
      @firestore.doc("chats/#{chat_id}").set({ default_timezone: timezone }, merge: true)
      @bot.api.send_message(chat_id: chat_id, text: "Default timezone updated to #{timezone}.")
    else
      @bot.api.send_message(chat_id: chat_id, text: "Invalid timezone selected.")
    end
  end

  def send_welcome_message(chat_id)
    welcome_message_text = "<b>Hello!</b> I am your Expense Tracker Bot!\n\n" \
                          "Please add transactions in the format: '@#{BOT_USERNAME} [Item] [Amount] [currency (optional)]'.\n\n" \
                          "For example, '@#{BOT_USERNAME} Lunch 20 SGD' or '@#{BOT_USERNAME} Starbucks Coffee 20'.\n\n" \
                          "You can even add Income with '@#{BOT_USERNAME} Salary +2000 SGD'.\n\n" \
                          "The Default currency is SGD. You can change it in the '/settings' command. \n\n" \
                          "For more information, use the '/help' command.";

    @bot.api.send_message(chat_id: chat_id, text: welcome_message_text, parse_mode: "html" )
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

  def send_settings_options(chat_id)
    kb = [
      Telegram::Bot::Types::InlineKeyboardButton.new(text: 'Change Default Currency', callback_data: 'settings_currency'),
      Telegram::Bot::Types::InlineKeyboardButton.new(text: 'Add Categories', callback_data: 'settings_add_categories')
      #,Telegram::Bot::Types::InlineKeyboardButton.new(text: 'Change Default Timezone', callback_data: 'settings_timezone')
    ]

    @bot.api.send_message(
      chat_id: chat_id,
      text: "Please choose a setting to configure:",
      reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: kb.each_slice(1).to_a)
    )
  end

  def send_currency_keyboard(chat_id)
    kb = VALID_CURRENCIES.map do |currency|
      Telegram::Bot::Types::InlineKeyboardButton.new(text: currency, callback_data: "currency_#{currency}")
    end.each_slice(2).to_a

    @bot.api.send_message(
      chat_id: chat_id,
      text: "Please choose a new default currency:",
      reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: kb)
    )
  end

  def send_timezone_keyboard(chat_id)
    kb = VALID_TIMEZONES.map do |timezone|
      Telegram::Bot::Types::InlineKeyboardButton.new(text: timezone, callback_data: "timezone_#{timezone}")
    end.each_slice(2).to_a

    @bot.api.send_message(
      chat_id: chat_id,
      text: "Please choose a new default timezone:",
      reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: kb)
    )
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
    balances = calculate_balances(user_totals, split_amount)

    balances_text = balances.map do |user, balance|
      if balance > 0
        "#{user_names[user]} is owed $#{'%.2f' % balance}"
      else
        "#{user_names[user]} owes $#{'%.2f' % balance.abs}"
      end
    end.join("\n")
  
    # Calculate net transactions required to balance the expenses
    net_transactions = calculate_net_transactions(balances, user_names)

    "Total expenses for the month of #{Date.today.strftime("%B")}: <b>$#{'%.2f' % total_expense}</b>\n\n" \
    "<b>Breakdown by category:</b>\n#{category_percentages}\n\n" \
    "<b>Expenses by user:</b>\n#{user_expenses}\n\n" \
    "Each person should pay: <b>$#{'%.2f' % split_amount}</b>\n\n" \
    "<b>Balances:</b>\n#{balances_text}\n\n" \
    "<b>Net Transactions to Settle Balances:</b>\n#{net_transactions}\n\n"
  end

  def calculate_balances(user_totals, split_amount)
    user_totals.transform_values { |amount| amount - split_amount }
  end

  def calculate_net_transactions(balances, user_names)
    positive_balances = balances.select { |_, balance| balance > 0 }
    negative_balances = balances.select { |_, balance| balance < 0 }
  
    transactions = []
  
    positive_balances.each do |user_pos, balance_pos|
      negative_balances.each do |user_neg, balance_neg|
        next if balance_pos == 0 || balance_neg == 0
  
        amount = [balance_pos, balance_neg.abs].min
  
        transactions << "#{user_names[user_neg]} should pay #{user_names[user_pos]} $#{'%.2f' % amount}"
  
        positive_balances[user_pos] -= amount
        negative_balances[user_neg] += amount
      end
    end
  
    transactions.join("\n")
  end

  def ensure_chat_and_user(chat_id, user_id, first_name)
    chat_ref = @firestore.doc("chats/#{chat_id}")
    chat_data = chat_ref.get.data || {}

    unless chat_data.key?(:custom_categories)
      chat_ref.set({ custom_categories: [] }, merge: true)
    end

    chat_ref.set({ chat_id: chat_id }, merge: true)

    user_ref = @firestore.doc("users/#{user_id}")
    user_ref.set({ user_id: user_id, first_name: first_name }, merge: true)

    chat_users_ref = @firestore.doc("chats/#{chat_id}/users/#{user_id}")
    chat_users_ref.set({ user_id: user_id }, merge: true) 
  end


  ### Handle Edit Expense Func
  def edit_expense(original_message, new_text, chat_id, user_id, is_group_chat: false)

    # Retrieve the default currency from Firestore
    chat_ref = @firestore.doc("chats/#{chat_id}")
    chat_data = chat_ref.get.data || {}
    default_currency = chat_data[:default_currency] || DEFAULT_CURRENCY

    puts default_currency

    # Parse the original and new expense messages
    original_match = is_group_chat ? 
      original_message.match(/^@#{BOT_USERNAME}\s+(.+?)\s+\$?([+-]?\d+(\.\d{1,2})?)\s*(\w{3})?$/) :
      original_message.match(/^(.+?)\s+\$?([+-]?\d+(\.\d{1,2})?)\s*(\w{3})?$/)
    
    new_match = is_group_chat ?
      new_text.match(/^@#{BOT_USERNAME}\s+(.+?)\s+\$?([+-]?\d+(\.\d{1,2})?)\s*(\w{3})?$/) :
      new_text.match(/^(.+?)\s+\$?([+-]?\d+(\.\d{1,2})?)\s*(\w{3})?$/)

    if original_match && new_match
      # Extract original and new expense details
      original_item, original_amount, original_currency = original_match[1], original_match[2].to_f, original_match[4] || default_currency
      new_item, new_amount, new_currency = new_match[1], new_match[2].to_f, new_match[4] || default_currency

      # Update Firestore transaction record based on the original expense details
      transactions = @firestore.collection("chats/#{chat_id}/transactions")
                            .where("user_id", "==", user_id)
                            .where("name", "==", original_item)
                            .where("amount", "==", original_amount)
                            .where("currency", "==", original_currency)
                            .get

      if transactions.any?
        transaction_ref = transactions.first.ref
        transaction_ref.set({
          name: new_item,
          amount: new_amount,
          currency: new_currency
        }, merge: true)

        @bot.api.send_message(chat_id: chat_id, text: "Expense updated successfully.")
      else
        @bot.api.send_message(chat_id: chat_id, text: "Original expense not found.")
      end
    else
      @bot.api.send_message(chat_id: chat_id, text: "Invalid format for updating expense.")
    end
  end

end
# Initialize the bot
expense_bot = ExpenseBot.new

post '/webhook' do
  update = JSON.parse(request.body.read)
  puts JSON.pretty_generate(update)

  secret_token = request.env['HTTP_X_TELEGRAM_BOT_API_SECRET_TOKEN']

  if secret_token == ENV["SECRET_TOKEN"]
    expense_bot.handle_webhook(update)
    status 200
  else
    status 403
  end
end