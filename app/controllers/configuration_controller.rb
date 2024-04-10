# coding: utf-8

# Copyright (C) 2010-2019 Íbúar ses / Citizens Foundation Iceland
# Authors Robert Bjarnason, Gunnar Grimsson, Gudny Maren Valsdottir & Alexander Mani Gautason
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

require 'fileutils'
require "csv"
require "net/http"
require 'cgi'
require 'uri'
require 'json'

class ConfigurationController < ApplicationController
  include ActionView::Helpers::DateHelper

  def boot
    puts "BOOTING"

    boot_state = "unexpected"
    exception = nil
    public_key = nil

    begin
      vote_table_exists = ActiveRecord::Base.connection.table_exist? 'votes'
      config_table_exists = ActiveRecord::Base.connection.table_exist? 'config'
      items_table_exists = ActiveRecord::Base.connection.table_exist? 'budget_ballot_items'
      areas_table_exists = ActiveRecord::Base.connection.table_exist? 'budget_ballot_areas'
      vote_count = (vote_table_exists and Vote.count) ? Vote.count : 0
      authenticated_vote_count = (vote_table_exists) ? Vote.where.not(:saml_assertion_id=>nil).count : 0
      items_count = (items_table_exists and BudgetBallotItem.count) ? BudgetBallotItem.count : 0
      areas_count = (areas_table_exists and BudgetBallotArea.count) ? BudgetBallotArea.count : 0
      if config_table_exists and BudgetConfig.first
        public_key = BudgetConfig.first.public_key
      else
        public_key = nil
      end
      client_config = (config_table_exists and BudgetConfig.first and BudgetConfig.first.client_config!=nil)
      auth_url_exists = (config_table_exists and BudgetConfig.first and BudgetConfig.first.auth_url!=nil)
      config_updated_at = (config_table_exists and BudgetConfig.first and BudgetConfig.first.updated_at)
      config_created_at = (config_table_exists and BudgetConfig.first and BudgetConfig.first.created_at)

      ballot_data_updated_at = (areas_table_exists and BudgetBallotArea.first and BudgetBallotArea.first.updated_at)
      total_voter_count = vote_table_exists ? Vote.where.not(:saml_assertion_id=>nil).distinct.count(:user_id_hash) : 0

      if auth_url_exists and client_config and public_key and areas_count>0 and items_count>0
        ready_for_voting = true
      else
        ready_for_voting = false
      end


      if vote_count>0 and public_key
        boot_state = "has_votes"
      elsif config_table_exists and vote_table_exists and public_key
        boot_state = "ready_for_config"
      end
    rescue Exception => e
      exception = "#{e}"
    end

    puts boot_state
    puts public_key
    puts vote_table_exists
    puts vote_count

    respond_to do |format|
      format.json { render :json => {:boot_state => boot_state,
                                     :vote_count => vote_count,
                                     :items_count => items_count,
                                     :authenticated_vote_count => authenticated_vote_count,
                                     :areas_count => areas_count,
                                     :client_config_exists => client_config,
                                     :auth_url_exists => auth_url_exists,
                                     :ready_for_voting => ready_for_voting,
                                     :public_key => public_key,
                                     :total_voter_count => total_voter_count,
                                     :config_created_at => config_created_at,
                                     :config_updated_at => config_updated_at,
                                     :ballot_data_updated_at => ballot_data_updated_at,
                                     :config_time_ago => config_updated_at ? distance_of_time_in_words_to_now(config_updated_at) : "never",
                                     :config_created_ago => config_created_at ? distance_of_time_in_words_to_now(config_created_at) : "never",
                                     :ballot_data_time_ago => ballot_data_updated_at ? distance_of_time_in_words_to_now(ballot_data_updated_at) : "never",
                                     :public_key_exists => public_key ? true : false,
                                     :exception => exception
                                    }
      }
    end
  end

  def clear_votes
    Vote.delete_all
    ActiveRecord::Base.connection.execute("TRUNCATE votes")
    respond_to do |format|
      format.json { render :json => {:ok => true} }
    end
  end

  def upload_client_config
    if Vote.count==0
      client_config = JSON.parse(params[:file].read)
      config = BudgetConfig.first
      config.client_config = client_config
      puts config.auth_url = client_config["auth_url"]
      config.saml_idp_cert_fingerprint = client_config["saml_idp_cert_fingerprint"]
      config.touch
      config.save
      respond_to do |format|
        format.json { render :json => {:ok => true} }
      end
    else
      respond_to do |format|
        format.json { render :json => {:ok => false} }
      end
    end
  end

  def download_client_config
    config = BudgetConfig.first
    if config and config.client_config
      send_data config.client_config, :type => 'application/json', :filename=>"open_active_voting_client_config_#{Time.now.strftime('%Y_%m_%d.%H_%M_%S')}.json"
    else
      render :file=>"#{Rails.root}/public/404.html", :status=>404
    end
  end

  def upload_ballot_data
    if Vote.count==0
      begin
        import_ballot_data_from_csv(params[:file].read)
      rescue Exception => e
        exception = "#{e}"
        puts exception
        respond_to do |format|
          format.json { render :json => {:ok => false, :exception => exception } }
        end
      end
      respond_to do |format|
        format.json { render :json => {:ok => true} }
      end
    else
      respond_to do |format|
        format.json { render :json => {:ok => false} }
      end
    end
  end

  def download_voting_database
    system "rake db:dump_backup_for_download"
    download_filename = Rails.root.join("Backups","sql","latest_for_download.sql")
    puts download_filename
    if File.exist?(download_filename)
      send_file download_filename, :filename=>"open_active_voting_database_#{Time.now.strftime('%Y_%m_%d.%H_%M_%S')}.sql"
    else
      render :file=>"#{Rails.root}/public/404.html", :status=>404
    end
  end

  def import_new_sql
    filePath = "#{Rails.root}/Backups/sql/latest_for_import.sql"
    FileUtils.mkdir_p("#{Rails.root}/Backups/sql")
    File.open(filePath, "wb") { |f| f.write(params[:file].read) }
    system "rake db:restore_sql"

    respond_to do |format|
      format.json { render :json => {:ok => true} }
    end
  end

  private

  def import_ballot_data_from_csv(csv_data)
    csv_data.force_encoding('UTF-8')
    BudgetBallotItem.delete_all
    ActiveRecord::Base.connection.execute("TRUNCATE budget_ballot_items")
    BudgetBallotArea.delete_all
    ActiveRecord::Base.connection.execute("TRUNCATE budget_ballot_areas")
    ActiveRecord::Base.connection.execute("TRUNCATE budget_ballot_item_translations")
    csv_data = CSV.parse(csv_data).to_a
    @budget_rows = remove_empty_rows(csv_data)

    puts "@items_start_line #{@items_start_line = get_items_start_line}"
    puts @locales = get_all_locales

    import_ballot_areas
    puts "@areas #{@areas}"
    import_ballot_items
  end

  def remove_empty_rows(budget_rows)
    rows = []
    budget_rows.each do |row|
      unless row[0].to_s.empty?
        rows << row
      else
        puts "Reject: #{row}"
      end
    end
    rows
  end

  def get_items_start_line
    items_start_row = nil
    @budget_rows.each_with_index do |row, index|
      if row[2] and row[2].downcase=='costs'
        items_start_row = index+1
        break
      end
    end
    if items_start_row
      items_start_row
    else
      raise "Could not find items start row"
    end
  end

  def get_all_locales
    locales = []
    @budget_rows.each_with_index do |row, index|
      if row[2] and row[2].downcase=='costs'
        puts "DEBUG: #{row[6..row.length]}]}"
        row[6..row.length].each_slice(2).with_index do |(name, desc), index|
          puts "DEBUG: #{name} #{desc} #{index}"
          if name.split("-")[1]
            locales << {
              :locale_code => name.split("-")[1],
              :index => (index*2)+6
            }

            puts "DEBUG: #{locales}"
          end
        end
        break
      end
    end
    if locales and locales.length>0
      locales
    else
      raise "Could not find locales"
    end
  end

  def import_ballot_areas
    @areas = []
    puts "import_ballot_areas"
    @budget_rows[0..@budget_rows.length].each_with_index do |row, index|
      puts index
      if row[2] and row[2].downcase=='costs'
        logger.info "Stopping import of areas at index #{index}"
        break
      end
      if row[0] and row[1] and row[0].downcase != "area name"
        puts "areas: #{row[0]} #{row[1]} #{row[2]}"
        puts "FOUND"
        area = BudgetBallotArea.create!(:budget_amount => get_price(row[1]))
        I18n.locale = "en"
        area.name = row[0]
        area.save
        I18n.locale = "is"
        area.name = row[0]
        area.save
        I18n.locale = "pl"
        area.name = row[0]
        area.save
        I18n.locale = "en"
        @areas << area
      end
      puts @areas
    end
  end

  def get_price(price)
    price = price.gsub(',','')
    price = price.gsub(' kr.','')
    price = price.to_f
  end

  def import_ballot_items
    @current_area_name = nil
    @current_area_id = nil
    @areas.each_with_index do |area, area_index|
      puts "AREA: #{area} - #{area_index}"
      @current_area_id = area.id
      @current_area_name = area.name.dup
      @budget_rows[@items_start_line..@budget_rows.length].each_with_index do |row, index|
        puts "index #{index} - #{row[0]} - #{@current_area_name} - #{@current_area_id}"
        if row[0].downcase==@current_area_name.downcase
          puts "FOUND"
          idea_url = row[1]
          if idea_url and idea_url!="" and idea_url.length>10
            if idea_url.downcase.ends_with?(".png") or idea_url.downcase.ends_with?(".jpg") or idea_url.downcase.ends_with?(".jpeg")
              image_url = idea_url
              idea_id = -1
            else
              idea_id, image_url = get_idea_id_and_image_from_url(idea_url)
              puts image_url
            end
          else
            idea_id = -1
          end

          price = get_price(row[2])
          if price>100000
            price = price/1000000
          end

          location_1 = row[3] and row[3].gsub(" ","")
          location_2 = row[4] and row[4].gsub(" ","")

          if location_2
            locations = "#{location_1},#{location_2}"
          else
            locations = location_1
          end

          pdf_url = row[5]

          item = BudgetBallotItem.create!(:price=>price,
            :idea_id=>idea_id,
            :budget_ballot_area_id=>@current_area_id,
            :locations=>locations,
            :image_url=>image_url,
            :pdf_url=>pdf_url,
            :idea_url=>idea_url)

          @locales.each_with_index do |locale, locale_index|
            I18n.locale = locale[:locale_code]
            name = row[locale[:index]]
            description = row[locale[:index]+1]
            #puts "LOCALE: #{locale} #{name} - #{description}"
            item.name = name
            item.description = description
            item.save
          end
        end
      end
    end
    puts "END import_ballot_items"
  end

  def get_idea_id_and_image_from_url(idea_url)
    puts "get_idea_id_and_image_from_url #{idea_url}"
    # Update the URL to target the API endpoint if needed
    idea_url = idea_url.gsub("/post/", "/api/posts/")
    puts idea_url

    # Extract the idea ID
    idea_id = idea_url.split('/').last

    # Parse the URL and prepare the HTTP request
    uri = URI.parse(idea_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https') # Enable SSL/TLS if using HTTPS

    req = Net::HTTP::Get.new(uri)
    req['Content-Type'] = "application/json"

    begin
      res = http.request(req)
      post_json = JSON.parse(res.body)

      # Initialize default image URL
      image_url = "https://i.imgur.com/sdsFAoT.png"

      if post_json["PostHeaderImages"] && !post_json["PostHeaderImages"].empty?
        # Assuming the structure and that the last element has the image URL you need
        if post_json["PostHeaderImages"].last["formats"]
          image_info = post_json["PostHeaderImages"].last["formats"]
          # Assuming image_info is a JSON string that needs parsing
          image_url = JSON.parse(image_info)[0] if image_info.is_a?(String)
        end
        puts post_json["PostHeaderImages"][0] # Log the first image for reference
        puts image_url # Log the determined image URL
      end

    rescue JSON::ParserError => e
      puts "Error parsing JSON response: #{e.message}"
    rescue => e
      puts "An error occurred: #{e.message}"
    end

    return idea_id, image_url
  end
end
