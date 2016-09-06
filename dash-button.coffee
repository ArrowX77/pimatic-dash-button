module.exports = (env) =>

  pcap = require 'pcap'
  stream = require 'stream'
  helper = require './helper'
  M = env.matcher
  Promise = env.require 'bluebird'
  assert = env.require 'cassert'
  _ = env.require 'lodash'

  class DashButtonPlugin extends env.plugins.Plugin

    init: (app, @framework, @config) =>
      # using a buffer size of 1 MB, should be enough for filtering ARP requests
      pcapSession = pcap.createSession(@config.interface, 'arp', 1024 * 1024)

      deviceConfigDef = require('./device-config-schema.coffee')

      @framework.deviceManager.registerDeviceClass 'DashButtonDevice',
        configDef: deviceConfigDef.DashButtonDevice
        createCallback: (config, lastState) =>
          return new DashButtonDevice(config, pcapSession)

      @framework.deviceManager.on 'discover', (eventData) =>

        discoveredButtons = {}

        @framework.deviceManager.discoverMessage(
          'pimatic-dash-button', "Waiting for dash button press. Please press your dash button now."
        )

        packetListener = (raw_packet) =>
          packet = pcap.decode.packet(raw_packet) #decodes the packet
          if packet.payload.ethertype == 2054 #ensures it is an arp packet
            # List of registered Mac addresses with IEEE
            # as of 18 July 2016 for Amazon Technologies Inc.
            # source: https://regauth.standards.ieee.org/standards-ra-web/pub/view.html#registries
            amazon_macs = ["747548","F0D2F1","8871E5","74C246","F0272D","0C47C9"
              ,"A002DC","AC63BE","44650D","50F5DA","84D6D0"]
            #getting the hardware address of the possible dash
            possible_dash =
              helper.int_array_to_hex(packet.payload.payload.sender_ha.addr)
            env.logger.debug 'detected possible dash button with mac address ' + possible_dash
            # filter for amazon mac addresses
            if possible_dash.slice(0,8).toString().toUpperCase().split(':').join('') in amazon_macs
              env.logger.debug 'detected new Amazon dash button with mac address ' + possible_dash
              config = {
                class: 'DashButtonDevice'
                address: possible_dash
              }
              hash = JSON.stringify(config)
              if discoveredButtons[hash]
                return
              discoveredButtons[hash] = true
              @framework.deviceManager.discoveredDevice(
                'pimatic-dash-button', 'Dash Button (' + possible_dash + ')', config
              )

        pcapSession.on('packet', packetListener)

        setTimeout(( =>
          pcapSession.removeListener("packet", packetListener)
        ), eventData.time)

  class DashButtonDevice extends env.devices.ButtonsDevice

    _listener: null

    constructor: (@config, @pcapSession) ->
      @id = @config.id
      @name = @config.name
      @config.buttons = [{"id": @id, "text": "Press"}]
      super(@config)

      @_listener = (raw_packet) =>
        packet = pcap.decode.packet(raw_packet) #decodes the packet
        if packet.payload.ethertype == 2054 #ensures it is an arp packet
          address = helper.int_array_to_hex(packet.payload.payload.sender_ha.addr)
          if address == @config.address
            @buttonPressed()

      @pcapSession.on 'packet', @_listener

    buttonPressed: ->
      env.logger.debug @id + ' was pressed'
      @_lastPressedButton = @id
      @emit 'button', @id
      return Promise.resolve()

    destroy: () ->
      super()
      @pcapSession.removeListener('packet', @_listener)

  return new DashButtonPlugin()
