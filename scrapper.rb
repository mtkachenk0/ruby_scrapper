#! /usr/bin/ruby
require 'watir'
require 'nokogiri'
require_relative 'exceptions'

#
class Scrapper
  attr_reader :browser, :authors, :history, :base_url
  ENDPOINTS = {
    base: '/', # well structured HTML with microdata markup and pagination buttons
    scroll: '/scroll', # same as /, but with infinite scrolling via AJAX calls.
    random: '/random', #  shows a single random quote.
    login: '/login', #  login page with CSRF token
    search: '/search.aspx', # an AJAX-based filter form that simulates ViewStates behavior.
    js: '/js', # the content is generated by JavaScript code.
    tableful: '/tableful', #  a messed-up layout based on tables.
    iframe: '/iframe',
    frames: '/frames'
  }.freeze

  def initialize(host = '127.0.0.1', port = 5000, driver = :chrome)
    raise ArgumentError unless [:firefox, :chrome, :phantom_js].include?(driver)

    @browser  = Watir::Browser.new(driver)
    @base_url = "http://#{host}:#{port}"
    @authors  = {} # name: about
    @history = {}
  end

  # Uses browser.goto
  # returns: true if url has been changed
  # used: browser#goto, Watir::Wait#until, browser#url
  def change_endpoint(endpoint)
    return true if browser.url == base_url + ENDPOINTS[endpoint]
    history[:prev_url] = browser.url
    browser.goto(base_url + ENDPOINTS[endpoint])
    Watir::Wait.until(timeout: 5) { history[:prev_url] != browser.url }
    !history[:prev_url] == browser.url
  end

  # used browser.driver#execute_script
  def raise_alert(text)
    browser.driver.execute_script("window.alert('#{text}')")
    sleep 1
    browser.alert.exists? && browser.alert.text.eql?(text)
  end

  # used: browser.alert#exists?, browser.alert#text,
  # browser.alert#close
  def handle_alert
    raise AssertionError, 'Alert does not exist' unless browser.alert.exists?
    puts "Alert text: #{browser.alert.text}"
    browser.alert.close
    !browser.alert.exists?
  end
  # Click next || previous button to test pagination
  # returns true if page num in url has been changed
  # used: browser#li, browser#url
  def change_page(direction)
    raise AttributeError unless [:next, :previous].include?(direction)
    begin
      history[:prev_page] = %r{\/(\d+)\/$}.match(browser.url)[1].to_i
    rescue NoMethodError
      history[:prev_page] = 1
    end
    browser.li(class: direction.to_s).a.click
    history[:current_page] = %r{\/(\d+)\/$}.match(browser.url)[1].to_i

    1 == (history[:prev_page] - history[:current_page]).abs
  end

  # returns array of quotes
  # used: browser#divs
  def page_quotes
    result = browser.divs(class: 'quote')
    raise AssertionError.new('No quotes found') if result.to_a.empty?
    result
  end

  # returns hash of parsed quote
  # used: element#spans, element#element, element#text
  # element#a, element#href, element#div, #element#links
  def parse_quote(quote, save_authors = false)
    quote_author           = quote.spans[1].element(class: 'author').text
    authors[quote_author]  = quote.spans[1].a.href if save_authors
    {
      text:   quote.spans[0].text,
      author: quote_author,
      tags:   quote.div.links.map(&:text) # a.k.a { |tag| tag.text }.compact
    }
  end

  # used: Watir::Wait#until
  def parse_random_quote
    change_endpoint(:random)
    Watir::Wait.until(timeout: 5) { browser.div(class: 'quote').exists? }
    parse_quote(page_quotes[0])
  end

  # used: browser#li, element#present?
  def parse_quotes_base
    change_endpoint(:base)
    result = []
    loop do
      result.concat(page_quotes.map { |quote| parse_quote(quote, true) }.compact)
      break unless browser.li(class: 'next').present?
      change_page(:next)
    end
    result
  end

  # used:  browser.driver#execute_script
  def parse_quotes_scroll
    change_endpoint(:scroll)
    result = []
    quotes_on_page = 0
    quotes_after_scroll = 1
    while quotes_on_page != quotes_after_scroll
      quotes_on_page = page_quotes.size
      browser.driver.execute_script('window.scrollBy(0, document.body.scrollHeight)')
      sleep 1
      quotes_after_scroll = page_quotes.size
    end
    result.concat(page_quotes.map { |quote| parse_quote(quote) }.compact)
  end

  # used: browser#iframe, iframe#div
  def parse_quotes_iframe
    change_endpoint(:iframe)
    iframe = browser.iframe(name: 'my_awesome_frame')
    parse_quote(iframe.div(class: 'quote'))
  end

  def parse_quotes_frames
    change_endpoint(:frames)
    json_frame = browser.frame(name: 'json_frame')
    random_frame = browser.frame(name: 'random_frame')
    !json_frame.text.empty? && !parse_quote(random_frame.div(class: 'quote')).empty?
  end

  # used: browser#select_list,  browser#select,
  # browser#select_value, browser#button#click
  # element#value
  # returns true if values were set
  def set_filters(author, tag)
    change_endpoint(:search) unless browser.url != base_url + ENDPOINTS[:search]
    dd_author = browser.select_list(id: 'author')
    dd_tag    = browser.select_list(id: 'tag')

    dd_author.select(author)
    dd_tag.select_value(tag)
    browser.button(name: 'submit_button').click
    dd_author.value == author && dd_tag.value == tag
  end

  # used: browser#select_list, browser#button
  # element#click, element#select_value, quote#spans
  def parse_quotes_by_filter(author = 'Mark Twain', tag = 'classic')
    change_endpoint(:search)
    result = []
    raise AssertionError, 'Filters were not set' unless set_filters(author, tag)
    result.concat(browser.divs(class: 'quote').map do |quote|
      {
        text:    quote.spans[0].text,
        author:  quote.spans[1].text,
        tags:    quote.spans[2].text
      }
    end.compact)
    result
  end

  # does the same thing as in :base endpoint
  def parse_quotes_js
    change_endpoint(:js)
    result = []
    loop do
      result.concat(page_quotes.map { |quote| parse_quote(quote) }.compact)
      break unless browser.li(class: 'next').present?
      change_page(:next)
    end
    result
  end

  # used: browser#table, browser#table#trs
  # browser#text
  def parse_quotes_tableful
    change_endpoint(:tableful)
    result = []
    table  = browser.table.trs[1...-1]
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
      break if browser.text.include?('No quotes found')
    end
    result
  end

  # used: browser#link, element#present?
  # browser#text_field, element#set,
  # browser#input, #element#click, Watir::Wait#until
  def login(username, password)
    raise AssertionError.new("You're already logged in") if browser.link(href: '/logout').present?
    change_endpoint(:login)
    browser.text_field(id: 'username').set(username)
    browser.text_field(id: 'password').set(password)
    browser.input(type: 'submit').click

    Watir::Wait.until(timeout: 5) { browser.link(href: '/logout').present? }
    browser.link(href: '/logout').present?
  end

  # used: browser#link, element#click
  # element#present?, Watir::Wait#until
  def logout
    raise AssertionError.new("You aren't logged in.") if browser.link(href: '/login').present?
    browser.link(href: '/logout').click
    Watir::Wait.until(timeout: 5) { browser.link(href: '/login').present? }
    browser.link(href: '/login').present?
  end
end

def run
  scrapper = Scrapper.new
  puts "Parsed random quote: #{!scrapper.parse_random_quote.empty?}"
  puts "Logged in: #{scrapper.login('user', 'mySupperPupper#sEcrEt')}"
  puts "Parsed all quotes using base page: #{scrapper.parse_quotes_base.size == 100}"
  puts "Logged out: #{scrapper.logout}"
  puts "Alert called #{scrapper.raise_alert('V ROT MNE NOGI')}"
  puts "Alert handled: #{scrapper.handle_alert}"
  puts "Parsed all quotes using ajax requests for scrolling: #{scrapper.parse_quotes_scroll.size == 100}"
  puts "Parsed all quotes using search filters: #{!scrapper.parse_quotes_by_filter.empty?}"
  puts "Parsed quotes from 2 frames: #{scrapper.parse_quotes_frames}"
  puts "Parsed all quotes using js code generator: #{scrapper.parse_quotes_js.size == 100}"
  puts "Parsed all quotes using tableful representation: #{scrapper.parse_quotes_tableful.size == 100}"
  puts "Parsed random quote inside iframe: #{!scrapper.parse_quotes_iframe.empty?}"
  puts "Browser closed: #{scrapper.browser.close}"
end

run
