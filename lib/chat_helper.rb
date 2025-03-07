# nxs-chat-redmine - plugin for Redmine
# Copyright (C) 2006-2014  Jean-Philippe Lang
# Copyright (C) 2017  Nixys Ltd.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

require 'net/http'
require 'uri'
require 'open-uri'
require 'json'

module Redmine
  module Helpers
    module Chat

      # Return hash with data from issue and journals (optional) objects
      #
      # Based on template from redmine/app/views/issues/show.api.rsb
      def self.issue_as_json(issue: nil, journals: nil)
        json = {}

        json[:id] = issue.id

        unless issue.project.nil?
          json[:project] = {:id => issue.project_id, :name => issue.project.name}



          unless issue.project.custom_field_values.nil?
            issue.project.custom_field_values.each do |custom_value|
              if custom_value.value.is_a?(Array)
              else
                json[:project]["#{custom_value.custom_field.name}"] = custom_value.value
              end
            end
          end

          unless issue.project.members.nil?
            json[:project][:members] = []
            issue.project.members.each do |member|
              membership = {
                :id => member.user.id,
                :name => member.user.name,
                :access => {
                  :view_current_issue => issue.visible?(member.user),
                  :view_private_notes => member.user.allowed_to?(:view_private_notes, issue.project)
                },
                :roles => []
              }
              member.roles.each do |role|
                membership[:roles] += [{
                  :id => role.id,
                  :name => role.name,
                  :permissions => {
                    :issues_visibility => role.issues_visibility,
                    :view_private_notes => role.has_permission?(:view_private_notes)
                  }
                }]
              end
              json[:project][:members] += [membership]
            end
          end
        end

        json[:tracker] = {:id => issue.tracker_id, :name => issue.tracker.name} unless issue.tracker.nil?
        json[:status] = {:id => issue.status_id, :name => issue.status.name} unless issue.status.nil?
        json[:priority] = {:id => issue.priority_id, :name => issue.priority.name} unless issue.priority.nil?
        json[:author] = {:id => issue.author_id, :name => issue.author.name} unless issue.author.nil?
        json[:assigned_to] = {:id => issue.assigned_to_id, :name => issue.assigned_to.name} unless issue.assigned_to.nil?
        json[:category] = {:id => issue.category_id, :name => issue.category.name} unless issue.category.nil?
        json[:fixed_version] = {:id => issue.fixed_version_id, :name => issue.fixed_version.name} unless issue.fixed_version.nil?
        json[:parent] = {:id => issue.parent_id} unless issue.parent.nil?

        json[:subject] = issue.subject
        json[:description] = issue.description
        json[:start_date] = issue.start_date
        json[:due_date] = issue.due_date
        json[:done_ratio] = issue.done_ratio
        json[:is_private] = issue.is_private
        json[:estimated_hours] = issue.estimated_hours
        json[:spent_hours] = issue.spent_hours

        # Custom values
        unless issue.custom_field_values.nil?
          json[:custom_fields] = []
          issue.custom_field_values.each do |custom_value|
            attrs = {:id => custom_value.custom_field_id, :name => custom_value.custom_field.name}
            attrs.merge!(:multiple => true) if custom_value.custom_field.multiple?

            if custom_value.value.is_a?(Array)
              attrs[:value] = []
              custom_value.value.each do |value|
                attrs[:value] += [value] unless value.blank?
              end
            else
              attrs[:value] = custom_value.value
            end
          json[:custom_fields] += [attrs]
          end
        end

        json[:created_on] = issue.created_on
        json[:updated_on] = issue.updated_on
        json[:closed_on] = issue.closed_on

        # Attachments
        unless issue.attachments.nil?
          json[:attachments] = []
          issue.attachments.each do |attachment|
            a = {}
            a["id"] = attachment.id
            a["filename"] = attachment.filename
            a["filesize"] = attachment.filesize
            a["content_type"] = attachment.content_type
            a["description"] = attachment.description
            #a["content_url"] = url_for(:controller => 'attachments', :action => 'download', :id => attachment, :filename => attachment.filename, :only_path => false) # TODO
            a["author"] = {:id => attachment.author.id, :name => attachment.author.name} unless attachment.author.nil?
            a["created_on"] = attachment.created_on

            json[:attachments] += [a]
          end
        end

        # TODO: relations

        # TODO: changesets

        # Journals
        unless journals.nil?
          json[:journals] = []
          journals.each do |journal|
            j = {}
            j[:id] = journal.id
            j[:user] = {:id => journal.user_id, :name => journal.user.name} unless journal.user.nil?
            j[:notes] = journal.notes
            j[:private_notes] = journal.private_notes
            j[:created_on] = journal.created_on
            j[:details] = []
            journal.visible_details.each do |detail|
              j[:details] += [{
                :property => detail.property,
                :name => detail.prop_key,
                :old_value => detail.old_value,
                :new_value => detail.value
              }]
            end
            json[:journals] += [j]
          end
        end

        # Watchers
        unless issue.watcher_users.nil?
          json[:watchers] = []
          issue.watcher_users.each do |user|
            json[:watchers] += [{ :id => user.id, :name => user.name }]
          end
        end

        json
      end

      # Sent event info to external web server (webhook)
      #
      # Arguments should support converting to JSON object
      def self.send_event(action: nil, data: nil)
        notifications_endpoint_url = data[:issue][:project]["notifications_endpoint"]?data[:issue][:project]["notifications_endpoint"]:Setting.plugin_nxs_chat['notifications_endpoint']

        begin
          uri = URI.parse(notifications_endpoint_url)
        rescue => e
          # Plugin is not configured properly
          logger.error "Parsing URI for notifications failed:\n"\
                       "  Exception: #{e.message}" if logger
          return
        end

        unless uri.kind_of?(URI::HTTP) or uri.kind_of?(URI::HTTPS)
          logger.error "Parsing URI for notifications failed" if logger
          return
        end

        # Prepare the data
        header = {
          'Content-Type' => 'application/json'
        }

        markdown = {}
        markdown[:title] = action
        markdown[:text] = "issue：[##{data[:issue][:id]}](http://39.101.181.32:13000/issues/#{data[:issue][:id]})\n> \n> "\
                      "项目: #{data[:issue][:project][:name]}\n> \n> "\
                      "类型: #{data[:issue][:tracker][:name]}\n> \n> "\
                      "主题：#{data[:issue][:subject]}\n> \n>"\
                      "状态: #{data[:issue][:status][:name]}\n> \n> "\
                      "优先级: #{data[:issue][:priority][:name]}\n> \n> "\
                      "指派给: #{data[:issue][:assigned_to]?data[:issue][:assigned_to][:name]:''}\n> \n> "\
                      "创建日期: #{data[:issue][:created_on]}\n> \n> "\
                      "更新日期:#{data[:issue][:updated_on]}\n> \n> "\
                      "### 描述\n> \n> "\
                      "    #{data[:description]}\n"
        json_data = JSON.generate({ :msgtype => "markdown", :markdown => markdown })
        #json_data = JSON.generate({ :action => action, :data => data })

        # Create the HTTP objects
        http = Net::HTTP.new(uri.host, uri.port)
        if uri.scheme == 'https'
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE
                #if Setting.plugin_nxs_chat['notifications_endpoint_ssl_verify_none']
        end
        request = Net::HTTP::Post.new(uri.request_uri, header)
        request.body = json_data

        # Send the request
        begin
          response = http.request(request)
        rescue => e
          logger.error "Sending notification failed:\n"\
                       "  URI: #{uri}\n"\
                       "  Exception: #{e.message}" if logger
          return
        end

        unless response.code.to_i == 200
          logger.error "Sending notification failed:\n"\
                       "  URI: #{uri}\n"\
                       "  Response code: #{response.code}" if logger
          return
        else
          logger.info "Notification has been sent successfully:\n"\
                      "  URI: #{uri}\n"\
                      "  Request: #{request.body}\n"\
                      "  Response: #{response.code}" if logger
        end
      end

      def self.logger
        Rails.logger
      end
    end
  end
end
