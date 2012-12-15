# Copyright 2010 Sean Cribbs, Sonian Inc., and Basho Technologies, Inc.
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
require 'riak'
require 'socket'
require 'timeout'
require 'base64'
require 'digest/sha1'
require 'riak/util/translation'

module Riak
  class Client
    class ProtobuffsBackend
      include Util::Translation

      # Message Codes Enum
      MESSAGE_CODES = %W[
          ErrorResp
          PingReq
          PingResp
          GetClientIdReq
          GetClientIdResp
          SetClientIdReq
          SetClientIdResp
          GetServerInfoReq
          GetServerInfoResp
          GetReq
          GetResp
          PutReq
          PutResp
          DelReq
          DelResp
          ListBucketsReq
          ListBucketsResp
          ListKeysReq
          ListKeysResp
          GetBucketReq
          GetBucketResp
          SetBucketReq
          SetBucketResp
          MapRedReq
          MapRedResp
       ].map {|s| s.intern }.freeze

      def self.simple(method, code)
        define_method method do
          socket.write([1, MESSAGE_CODES.index(code)].pack('NC'))
          decode_response
        end
      end

      attr_accessor :client
      def initialize(client)
        @client = client
      end

      simple :ping,          :PingReq
      simple :get_client_id, :GetClientIdReq
      simple :server_info,   :GetServerInfoReq
      simple :list_buckets,  :ListBucketsReq

      private
      # Implemented by subclasses
      def decode_response
        raise NotImplementedError
      end

      def socket
        @socket ||= new_socket
      end

      def new_socket
        socket = nil
        begin
          Timeout.timeout(2) do
            socket = TCPSocket.new(@client.host, @client.pb_port)
            socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true)
          end
        rescue Exception => e
          msg = "Exceeded timeout on connect to #{@client.host}:#{@client.pb_port} : #{e.class.name}, #{e.message}"
          Rails.ha_store.blacklist_server!(@client.host, @client.pb_port)
          next_server = Rails.ha_store.get_next_server
          @client.host = next_server[:host]
          @client.pb_port = next_server[:pb_port]
          msg += ". Server changed to #{@client.host}:#{@client.pb_port}" if @client.host && @client.pb_port
          Rails.logger.warn(msg) if Rails.logger
          retry if @client.host && @client.pb_port
        end
        socket
      end

      def reset_socket
        @socket.close if @socket && !@socket.closed?
        @socket = nil
      end

      UINTMAX = 0xffffffff
      QUORUMS = {
        "one" => UINTMAX - 1,
        "quorum" => UINTMAX - 2,
        "all" => UINTMAX - 3,
        "default" => UINTMAX - 4
      }.freeze

      def normalize_quorum_value(q)
        QUORUMS[q.to_s] || q.to_i
      end

      # This doesn't give us exactly the keygen that Riak uses, but close.
      def generate_key
        Base64.encode64(Digest::SHA1.digest(Socket.gethostname + Time.now.iso8601(3))).tr("+/","-_").sub(/=+\n$/,'')
      end
    end
  end
end
