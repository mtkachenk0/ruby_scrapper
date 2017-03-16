#! /usr/bin/ruby
require "optparse"
require 'watir'
require 'pry'
require 'logger'
require_relative 'exceptions'

class String
  def colorize(color_code)
    "\e[#{color_code}m#{self}\e[0m"
  end

  def red
    colorize(31)
  end

  def green
    colorize(32)
  end
end

#
class Scrapper
  ATTRIBUTES = [:browser, :history, :base_url, :action_log, :logger].freeze
  attr_reader *ATTRIBUTES

  ENDPOINTS = {
    base:     '/',            # microdata markup and pagination
    scroll:   '/scroll',      # same as /,with infinite scrolling via AJAX calls
    login:    '/login',       # login page with CSRF token
    search:   '/search.aspx', # an AJAX-based filter form
    js:       '/js',          # the content is generated by JavaScript code.
    tableful: '/tableful',    # a messed-up layout based on tables.
    iframe:   '/iframe',      # iframe testing
    frames:   '/frames',      # frameset testing
    form:     '/form'         # checkboxes, radios, text_fields here...
  }.freeze

  CREDENTIALS = ['user', 'mySupperPupper#sEcrEt'].freeze
  ALERT_TEXT  = 'the best alert text youve ever seen'.freeze

  def initialize(url, remote_browser_url, driver)
    raise ArgumentError, 'Invalid driver' unless [:firefox, :chrome, :phantom_js].include?(driver.to_sym)
    @logger            = Logger.new(STDOUT)
    @logger.level      = Logger::WARN
    @logger.formatter  = proc { |severity, datetime, progname, msg|
      Logger::Formatter.new.call(severity, datetime, progname, msg.dump)
    }

    @caps = Selenium::WebDriver::Remote::Capabilities.send(
      driver,
      {
          javascript_enabled:    true,
          css_selectors_enabled: true,
          takes_screenshot:      true
      }
    )
  
    @browser = Watir::Browser.new(
      :remote,
      url: remote_browser_url,
      desired_capabilities: @caps
    )
    @base_url          = url
    @history           = {}
    @action_log        = {}
    update_action_log(:init, true)
  end

  def update_action_log(key, value)
    raise TypeError, 'Boolean is required for <value>' unless value.is_a?(TrueClass) || value.is_a?(FalseClass)
    logger.warn("Action failed: #{key}: #{value} in #{caller[0]}".red) unless value
    action_log[key] = value unless action_log.key?(key)
    printf "%-50s [%s]\n", key, value ? 'OK'.green : 'FAIL'.red
    value
  end

  # add basic browser methods here...
  # actions: goto, url, driver, title, html, body
  def test_base_methods
    browser.goto('https://google.com')

    update_action_log(:goto,   browser.title.eql?('Google'))
    update_action_log(:title,  !(browser.title.nil? || browser.title.empty?))
    update_action_log(:url,    !(browser.url.nil? || browser.url.empty?))
    update_action_log(:driver, !browser.driver.nil?)
    update_action_log(:html,   !browser.html.nil? && browser.html.include?('<!DOCTYPE html>'))
    update_action_log(:body,   !browser.body.nil? && browser.body.divs.size > 1)
  end

  def prettify_action_log
    longest_key = action_log.keys.max_by(&:length)
    action_log.each_pair do |mtd, success|
      printf "%-#{longest_key.length}s [%s]\n", mtd, success ? 'OK'.green : 'FAIL'.red
    end
  end

  def change_endpoint(endpoint)
    current_url = browser.url
    return if current_url == base_url + ENDPOINTS[endpoint]
    browser.goto(base_url + ENDPOINTS[endpoint])
    Watir::Wait.until(timeout: 60) { current_url != browser.url }
  end

  # actions: execute_script, alert_raised
  # def alert_create
  #   browser.driver.execute_script("window.alert('#{ALERT_TEXT}')")
  #   sleep 1
  #   update_action_log('driver#execute_script(window.alert())', browser.alert.exists?)
  #   update_action_log(:alert_raised, browser.alert.exists? && browser.alert.text.eql?(ALERT_TEXT))
  # end

  # # actions: alert, alert_text, alert_closed
  # def alert_handle
  #   raise AssertionError, 'Alert does not exist' unless browser.alert.exists?
  #   text = browser.alert.text
  #   update_action_log(:alert, browser.alert.exists?)
  #   update_action_log(:alert_text, text == ALERT_TEXT)
  #   browser.alert.close
  #   update_action_log(:alert_closed, !browser.alert.exists?)
  # end

  # Click next or previous button to test pagination
  # returns true if page num in url has been changed
  # actions: browser#li, element#a
  def change_page(direction)
    raise AttributeError unless [:next, :previous].include?(direction)
    begin
      history[:prev_page] = %r{\/(\d+)\/$}.match(browser.url)[1].to_i
    rescue NoMethodError
      history[:prev_page] = 1
    end
    li = browser.li(class: direction.to_s)
    update_action_log(:li, !li.nil? && li.present?)
    a = li.a
    update_action_log(:a, !a.nil? && a.present?)
    browser.li(class: direction.to_s).a.click

    history[:current_page] = %r{\/(\d+)\/$}.match(browser.url)[1].to_i

    update_action_log(
      direction.to_s + 'button_click',
      1 == (history[:prev_page] - history[:current_page]).abs
    )
  end

  # .............................................................
  # actions: browser#divs
  def page_quotes
    result = browser.divs(class: 'quote')
    raise AssertionError, 'No quotes found' if result.to_a.empty?
    update_action_log(:divs, !result.to_a.empty?)
    result
  end

  # actions: element#spans, element#small, element#text
  # element#links, element#div
  def parse_quote(quote)
    update_action_log(:spans, !quote.spans.to_a.empty?)

    quote_author = quote.spans[1].small
    update_action_log(:small, !quote_author.nil? && quote_author.present?)

    tags = quote.div.links.map(&:text) # a.k.a { |tag| tag.text }
    update_action_log(:div, !quote.div.nil? && quote.div.present?)
    update_action_log(:links, !(quote.div.links.nil? || quote.div.links.to_a.empty?))
    update_action_log('element#text', !tags.empty?)
    {
      text:   quote.spans[0].text,
      author: quote_author.text,
      tags:   tags
    }
  end

  # actions: browser#li
  # uses page_quotes, parse_quotes, change_page methods(that are useful)
  # that's why we need to call this method, but 2 cycle passage are enough
  def parse_quotes_base
    change_endpoint(:base)
    result = []
    loop do
      result.concat(page_quotes.map { |quote| parse_quote(quote) }.compact)
      # change class: to 'next' to go though all cycle
      break unless browser.li(class: 'previous').present? # only 2 pages
      change_page(:next)
    end
    result
  end

  # actions: driver.execute_script
  def test_scroll
    change_endpoint(:scroll)
    quotes_on_page = 0
    quotes_after_scroll = 1
    while quotes_on_page != quotes_after_scroll
      quotes_on_page = page_quotes.size
      browser.driver.execute_script(
        'window.scrollBy(0, document.body.scrollHeight)'
      )
      sleep 1
      quotes_after_scroll = page_quotes.size
    end
    update_action_log(
      'driver#execute_script(window.scrollBy())',
      quotes_after_scroll > 1
    )
  end

  # actions: iframe
  def test_iframe
    change_endpoint(:iframe)
    page_html = browser.html
    iframe = browser.iframe(name: 'my_awesome_frame')
    update_action_log(:iframe, !iframe.nil? && iframe.present?)
    iframe_html = iframe.html
    update_action_log(:iframe_html, !iframe_html.nil? && page_html != iframe_html)
  end

  # actions: frame
  def test_frames
    change_endpoint(:frames)
    json_frame = browser.frame(name: 'json_frame')
    random_frame = browser.frame(name: 'random_frame')
    update_action_log(
      :frame,
      [
        !json_frame.nil? && json_frame.present? && !json_frame.text.empty?,
        !random_frame.nil? && random_frame.present? &&
         !parse_quote(random_frame.div(class: 'quote')).empty?
      ].all?
    )
  end

  # actions: option, button, click
  # select_list, options, select_value, select, value,
  # returns true if values were set
  def set_random_filters
    change_endpoint(:search)

    dd_author = browser.select_list(id: 'author')
    dd_tag    = browser.select_list(id: 'tag')
    update_action_log(
      :select_list,
      [
        !dd_author.nil? && dd_author.present? && dd_author.respond_to?(:options),
        !dd_tag.nil?    && dd_tag.present?    && dd_tag.respond_to?(:options)
      ].all?
    )

    dd_author_options = dd_author.options
    update_action_log(:options, dd_author_options.size == 50)

    author = dd_author_options[(0..dd_author_options.size).to_a.sample].text
    dd_author.select_value(author)
    update_action_log(:select_value, dd_author.value == author)
    update_action_log(:value, !dd_author.value.empty?)

    tag = dd_tag.option(index: (1..dd_tag.options.size - 1).to_a.sample)
    tag.select
    update_action_log(:select, dd_tag.value == tag.text)

    browser.button(name: 'submit_button').click
    sleep 2
    update_action_log(:button_click, !page_quotes.to_a.empty?)
    dd_author.value == author && dd_tag.value == tag
  end

  def generate_string
    (0...50).map { ('a'..'z').to_a[rand(26)] }.join
  end

  def test_form
    change_endpoint(:form)
    input_field = browser.input(id: 'entry_1000000')
    update_action_log(:input_text_field, !input_field.nil? && input_field.present?)
    text = generate_string
    input_field.send_keys(text)
    update_action_log(:send_keys, input_field.value.eql?(text))

    text_field = browser.textarea(id: 'entry_1000001')
    update_action_log(:textarea, !text_field.nil? && text_field.present?)
    text = generate_string
    text_field.set(text)
    update_action_log(:set, text_field.value.eql?(text))

    radio_button = browser.radio(value: 'Watir')
    update_action_log(:radio_set?, !radio_button.set?) # should be false
    radio_button.set
    update_action_log(:radio_set, radio_button.set?) # should be true

    checkboxes = browser.checkboxes
    update_action_log(:checkboxes, checkboxes.to_a.size == 3)
    checkbox = browser.checkbox(value: 'Python')
    update_action_log(:checkbox, checkbox.respond_to?(:set?))
    checkbox.set
    checkboxes[0].set
    update_action_log(:checkbox_set, checkbox.set? && checkboxes[0].set?)
    checkboxes[0].clear
    update_action_log(:checkbox_clear, !checkboxes[0].set?)

    drop_down_box = browser.div(id: 'entry_1000004')
    button = drop_down_box.button
    update_action_log(
      :js_dropdown_button,
      !button.nil? && button.present? && button.respond_to?(:click)
    )
    button.click
    choice = drop_down_box.div.links.to_a.sample
    choice.click
    update_action_log(
      :js_dropdown_option_select,
      drop_down_box.button.value == choice.value
    )

    table = browser.table(id: 'entry_1000005')
    update_action_log(:table, !table.nil? && table.respond_to?(:trs))
    table.td(value: '4').set # it's radio button

    div = browser.div(class: 'ss-grid')
    update_action_log(:div, !div.nil? && div.present?)
    label = div.label(for: 'entry_1787931591')
    update_action_log(:label, !label.nil? && label.present?)
    thead = div.thead
    update_action_log(:thead, !thead.nil? && thead.present?)
    tbody = div.tbody
    update_action_log(:tbody, !tbody.nil? && tbody.present?)
    trs = tbody.trs
    update_action_log(:trs, !trs.nil? && !trs.to_a.empty?)
    # just pass through it. we've already tested radiobuttons
    radio_button1 = browser.element(
      css: 'tr.ss-gridrow:nth-child(1) > td:nth-child(3) > label:nth-child(1) > div:nth-child(1) > #group_1000006_2'
    )
    radio_button1.click
    update_action_log(:element_by_css, browser.radio(id: 'group_1000006_2').set?)
    radio_button2 = browser.element(xpath: '//*[@id="group_1000007_4"]')
    radio_button2.click
    update_action_log(:element_by_xpath, browser.radio(id: 'group_1000007_4').set?)

    # overlapping links
    update_action_log(
      :overlapping_links_present?,
      browser.div(id: 'overlapping').links.map(&:present?) == [false, true, true]
    )
    update_action_log(
      :overlapping_links_exists?,
      browser.div(id: 'overlapping').links.map(&:exists?).all?
    )
    update_action_log(
      :overlapping_links_visible?,
      browser.div(id: 'overlapping').links.map(&:visible?) == [false, true, true]
    )

    submit = browser.button(name: 'submit')
    update_action_log(:submit, !submit.nil? && submit.present? && submit.respond_to?(:click))
    submit.click
    sleep 3
    form_submitted_by_text  = browser.text.downcase.include? 'your response has been recorded'
    form_submitted_by_title = browser.title == 'Thanks!'
    update_action_log(:browser_text, form_submitted_by_text)
    update_action_log(:browser_title, form_submitted_by_title)
  end

  # actions: table, trs, tr_text
  # browser#text
  def parse_quotes_tableful
    change_endpoint(:tableful)
    result = []
    table  = browser.table
    update_action_log(:table, !table.nil? && table.respond_to?(:trs))
    table = table.trs[1...-1]
    update_action_log(:trs, !table.nil? && !table.empty?)

    page = 1
    loop do
      table.each_with_index do |tr, i|
        next if i.odd?
        quote, author = table[i].text.split(' Author: ')
        result.push({
          text: quote,
          author: author,
          tags: table[i + 1].text.split[1..-1]
        })
      end
      page += 1
      browser.goto(base_url + ENDPOINTS[:tableful] + "/page/#{page}")
      #break if browser.text.include?('No quotes found')
      break if page == 2
    end
    result
  end

  # actions: text_field, set_text, input
  # submit_login, link
  def login
    username, password = CREDENTIALS
    raise AssertionError, "You're already logged in" if browser.link(href: '/logout').present?
    change_endpoint(:login)
    username_field = browser.text_field(id: 'username')
    update_action_log(:text_field, !username_field.nil? && username_field.present?)
    username_field.set(username)
    update_action_log(:set_text, username_field.value == username)

    browser.text_field(id: 'password').set(password)
    input_button = browser.input(type: 'submit')
    update_action_log(:input, !input_button.nil? && input_button.present?)

    input_button.click
    sleep 2
    update_action_log(:submit_login, browser.link(href: '/logout').present?)
    update_action_log(
      :link,
       browser.link(href: '/logout').present? || browser.link(href: '/login').present?
    )
    browser.link(href: '/logout').present?
  end

  # used: browser#link, element#click
  # element#present?, Watir::Wait#until
  def logout
    raise AssertionError.new("You aren't logged in.") if browser.link(href: '/login').present?
    browser.link(href: '/logout').click
    Watir::Wait.until(timeout: 5) { browser.link(href: '/login').present? }
    logged_out = browser.link(href: '/login').present?
    update_action_log(:logout, logged_out)
    logged_out
  end
end

def run(options)
  started  = Time.now 
  scrapper = Scrapper.new(options[:base_url], options[:remote_browser_url], options.fetch(:driver) || :chrome)
  (scrapper.methods - Object.methods - Scrapper::ATTRIBUTES).sort!.each do |mtd|
    mtd = scrapper.method(mtd)
    if mtd.parameters == []
      mtd.call
    end
  end
  #puts scrapper.prettify_action_log
  puts "Test passed with #{'no' if scrapper.action_log.values.all?} errors"
ensure
  scrapper.browser.close if scrapper
  puts "Elapsed time: #{Time.now - started}s"
end


options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: scrapper.rb [options]"

  opts.on('-b', '--base_url   URL',            '*Base url')    { |v| options[:base_url] = v }
  opts.on('-r', '--remote_url URL',            '*Remote host') { |v| options[:remote_browser_url] = v }
  opts.on('-d', '--driver     chrome|firefox', 'Driver')       { |v| options[:driver] = v }
  opts.on('-c', '--count      INT',            '*Driver instances amount')  

end.parse!


run(options)

# TODO: add hover!
