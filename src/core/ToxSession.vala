using ToxCore; // only in this file
using ToxEncrypt; // only in this file
using Ricin;

/**
* This class defines various methods, signals and properties related to toxcore handling.
* This class is intended to be used as an "intermediate" class between the .vapi and the Ricin code.
**/
public class Ricin.ToxSession : Object {
  /**
  * This property allow us to stop ToxCore internal loop simply. But we'll prefer using this.toxcore_stop().
  **/
  private bool tox_started { get; private set; default = false; }
  
  /**
  * This property is a switch to know whether or not Toxcore connected to the network.
  **/
  public bool tox_connected { get; private set; default = false; }

  /**
  * This property defines the loaded profile used in this instance.
  **/
  public Profile current_profile { get; private set; }

  /**
  * This defines the Tox instance from libtoxcore.vapi
  **/
  internal ToxCore.Tox tox_handle;

  /**
  * This aims to "cache" the options for the duration of the toxcore execution.
  **/
  public unowned ToxCore.Options? tox_options;

  /**
  * We keep a list of contacts thanks to the ContactsList class.
  **/
  private ContactsList contacts_list { private get; private set; }
  
  /**
  * We keep a list of groupchats thanks to the GroupchatsList class.
  **/
  private GroupchatsList groupchats_list { private get; private set; }

  /**
  * Signal: Triggered once the Tox connection state changes.
  **/
  public signal void tox_connection (bool online);

  /**
  * Signal: Triggered once the Tox bootstraping state is finished.
  **/
  public signal void tox_bootstrap_finished ();
  
  /**
  * Signal: Triggered once a contact request is received.
  * Use accept()/reject() methods from IRequest to interact with the `request` object.
  **/
  public signal void contact_request (ContactRequest request); // TODO: Write the ContactRequest interface.
  
  /**
  * Signal: Triggered once a contact request has been accepted.
  **/
  public signal void contact_request_accepted (IPerson contact, ContactRequest request);
  
  /**
  * Signal: Triggered once a contact request has been rejected.
  **/
  public signal void contact_request_rejected (ContactRequest request);
  
  /**
  * Signal: Triggered once a groupchat request is received.
  * @except {bool} - Signal handler needs to return true to accept the CR, false to reject it.
  **/
  public signal bool groupchat_request (GroupchatRequest request); // TODO: Write the GroupchatRequest interface.
  
  /**
  * Signal: Triggered once a groupchat request has been accepted.
  **/
  public signal void groupchat_request_accepted (Groupchat groupchat, GroupchatRequest request);
  
  /**
  * Signal: Triggered once a groupchat request has been rejected.
  **/
  public signal void groupchat_request_rejected (GroupchatRequest request);
  
  /**
  * Signal: Triggered once the contacts list needs to be refreshed (friend added, etc).
  **/
  public signal void contacts_list_needs_update ();

  /**
  * ToxSession constructor.
  * Here we init our ToxOptions, load the profile, init toxcore, etc.
  **/
  public ToxSession (Profile? profile, Options? options) throws ErrNew {
    this.current_profile = profile;
    this.tox_options = options;

    // If options is null, let's use default values.
    if (this.tox_options == null) {
      Options opts = ToxOptions.create ();
      this.tox_options = opts;
    }

    ERR_NEW error;
    this.tox_handle = new ToxCore.Tox (this.tox_options, out error);

    switch (error) {
      case ERR_NEW.NULL:
        throw new ErrNew.Null ("One of the arguments to the function was NULL when it was not expected.");
      case ERR_NEW.MALLOC:
        throw new ErrNew.Malloc ("The function was unable to allocate enough memory to store the internal structures for the Tox object.");
      case ERR_NEW.PORT_ALLOC:
        throw new ErrNew.PortAlloc ("The function was unable to bind to a port.");
      case ERR_NEW.PROXY_BAD_TYPE:
        throw new ErrNew.BadProxy ("proxy_type was invalid.");
      case ERR_NEW.PROXY_BAD_HOST:
        throw new ErrNew.BadProxy ("proxy_type was valid but the proxy_host passed had an invalid format or was NULL.");
      case ERR_NEW.PROXY_BAD_PORT:
        throw new ErrNew.BadProxy ("proxy_type was valid, but the proxy_port was invalid.");
      case ERR_NEW.PROXY_NOT_FOUND:
        throw new ErrNew.BadProxy ("The proxy address passed could not be resolved.");
      case ERR_NEW.LOAD_ENCRYPTED:
        throw new ErrNew.LoadFailed ("The byte array to be loaded contained an encrypted save.");
      case ERR_NEW.LOAD_BAD_FORMAT:
        throw new ErrNew.LoadFailed ("The data format was invalid. This can happen when loading data that was saved by an older version of Tox, or when the data has been corrupted. When loading from badly formatted data, some data may have been loaded, and the rest is discarded. Passing an invalid length parameter also causes this error.");
    }

    // We get a reference of the handle, to avoid ddosing ourselves with a big contacts list.
    // unowned ToxCore.Tox handle = this.tox_handle;

    this.tox_bootstrap_nodes.begin ();
    this.init_signals ();
    
    /**
    * TEMP DEV ZONE.
    **/
    uint8[] toxid = new uint8[ToxCore.ADDRESS_SIZE];
    this.tox_handle.self_get_address (toxid);
    print ("ToxID: %s\n", Utils.Helpers.bin2hex (toxid));
  }

  /**
  * This methods initialize all the tox callbacks and "connect" them to this class signals.
  **/
  private void init_signals () {
    this.tox_handle.callback_self_connection_status ((handle, status) => {
      if (status != ConnectionStatus.NONE) {
        this.tox_connected = true;
        debug ("Connected to the Tox network.");
      } else {
        this.tox_connected = false;
        debug ("Disconnected from the Tox network.");
      }

      this.tox_connection (this.tox_connected);
    });
    
    this.tox_handle.callback_friend_request (this.on_friend_request);
  }

  /**
  * This methods handle bootstraping to the Tox network.
  * It takes care of reading and deserializing the dht-nodes.json file stored in resources.
  * It also takes care of bootstraping correctly by using TCP as a fallback, and IPv6 in priority.
  **/
  private async void tox_bootstrap_nodes () {
    debug ("B: Started Tox bootstraping process...");

    var json = new Json.Parser ();
    Bytes bytes;
    bool json_parsed = false;

    try {
      bytes = resources_lookup_data ("/im/ricin/client/jsons/dht-nodes.json", ResourceLookupFlags.NONE);
    } catch (Error e) {
      error (@"B: Cannot load dht-nodes.json, error: $(e.message)");
    }

    try {
      uint8[] json_content = bytes.get_data ();
      json_parsed = json.load_from_data ((string) json_content, (ssize_t) bytes.get_size ());
    } catch (Error e) {
      error (@"B: Cannot parse dht-nodes.json, error: $(e.message)");
    }

    if (json_parsed) {
      debug ("B: dht-nodes.json was found, parsing it.");

      ToxDhtNode[] nodes = {};
      var nodes_array = json.get_root ().get_object ().get_array_member ("servers");

      // Let's get our nodes from the JSON file as ToxDhtNode objects.
      nodes_array.foreach_element ((array, index, node) => {
        nodes += ((ToxDhtNode) Json.gobject_deserialize (typeof (ToxDhtNode), node));
      });

      debug ("B: Parsed dht-nodes.json, bootstraping in progress...");

      while (!this.tox_connected) {
        // Bootstrap to 6 random nodes, faaast! :)
        for (int i = 0; i < 6; i++) {
          ToxDhtNode rnd_node = nodes[Random.int_range (0, nodes.length)];

          bool success = false;
          bool try_ipv6 = this.tox_options.ipv6_enabled && rnd_node.ipv6 != null;

          // First we try UDP IPv6, if available for this node.
          if (!success && try_ipv6) {
            debug ("B: UDP IPv6 bootstrap %s:%d by %s", rnd_node.ipv6, (int) rnd_node.port, rnd_node.owner);
            success = this.tox_handle.bootstrap (
              rnd_node.ipv6,
              (uint16) rnd_node.port,
              Utils.Helpers.hex2bin (rnd_node.pubkey),
              null
            );
          }

          // Then, if bootstrap didn't worked in UDP IPv6, we use UDP IPv4.
          if (!success) {
            debug ("B: UDP IPv4 bootstrap %s:%d by %s", rnd_node.ipv4, (int) rnd_node.port, rnd_node.owner);
            success = this.tox_handle.bootstrap (
              rnd_node.ipv4,
              (uint16) rnd_node.port,
              Utils.Helpers.hex2bin (rnd_node.pubkey),
              null
            );
          }

          // If UDP didn't worked, let's do the same but with TCP IPv6.
          if (!success && try_ipv6) {
            debug ("B: TCP IPv6 bootstrap %s:%d by %s", rnd_node.ipv6, (int) rnd_node.port, rnd_node.owner);
            success = this.tox_handle.add_tcp_relay (
              rnd_node.ipv6,
              (uint16) rnd_node.port,
              Utils.Helpers.hex2bin (rnd_node.pubkey),
              null
            );
          }

          // Then, if bootstrap didn't worked in TCP IPv6, we use TCP IPv4.
          if (!success) {
            debug ("B: TCP IPv4 bootstrap %s:%d by %s", rnd_node.ipv4, (int) rnd_node.port, rnd_node.owner);
            success = this.tox_handle.add_tcp_relay (
              rnd_node.ipv4,
              (uint16) rnd_node.port,
              Utils.Helpers.hex2bin (rnd_node.pubkey),
              null
            );
          }
        }

        // We wait 5s without blocking the main loop.
        Timeout.add (5000, () => {
          this.tox_bootstrap_nodes.callback ();
          return false; // We could use Source.REMOVE instead but false is better for old GLib versions.
        });

        yield;
      }

      debug ("B: Boostraping to the Tox network finished successfully.");
      this.tox_bootstrap_finished ();
    }
  }

  /**
  * This methods allow to kill the ToxCore instance properly.
  **/
  private void tox_disconnect () {
    this.tox_started = false;

    this.tox_handle.kill ();
    this.tox_connection (false); // Tox connection stopped, inform the signal.
  }

  /**
  * Method to call in order to start toxcore execution loop.
  **/
  public void tox_run_loop () {
    this.tox_started = true;
    this.tox_schedule_loop_iteration ();
  }

  /**
  * Iteration loop used to maintain the toxcore instance updated.
  **/
  private void tox_schedule_loop_iteration () {
    Timeout.add (this.tox_handle.iteration_interval (), () => {
      if (this.tox_started == false) { // Let's stop the iteration if this var is set to true.
        return true;
      }

      this.tox_handle.iterate ();
      this.tox_schedule_loop_iteration ();
      return false;
    });
  }
  
  /**
  * Friend request callback handler.
  **/
  private void on_friend_request (Tox handle, uint8[] public_key, uint8[] message) {
    public_key.length = ToxCore.PUBLIC_KEY_SIZE; // Fix an issue with Vala.
    
    string request_pubkey  = Utils.Helpers.bin2hex (public_key);
    string request_message = (string) message;
    
    print ("Friend request received:\n");
    print ("-- %s\n", request_pubkey);
    print ("-- %s\n", request_message);
    
    ContactRequest request = new ContactRequest (request_pubkey, request_message);
    request.state_changed.connect ((old_state, state) => {
      if (state == RequestState.ACCEPTED) {
        uint32 tox_contact_number = this.tox_handle.friend_add_norequest (public_key, null);
        
        try {
          this.current_profile.save_data ();
        } catch (ErrDecrypt e) {
          debug (@"Cannot save the newly added friend to the Tox save, error: $(e.message)");
        }
      
        /**
        * TODO: Add the newly created contact to contacts_list.
        **/
        Contact contact = new Contact (ref this.tox_handle, tox_contact_number, public_key);
        this.contact_request_accepted (contact, request);
        
        /**
        * TODO: Log the request in log file. "Contact request was accepted at time/day... $details"
        **/
      } else if (state == RequestState.REJECTED) {
        /**
        * TODO: Log the request in log file. "Contact request was rejected at time/day... $details"
        **/
        this.contact_request_rejected (request);
      }
    });

    this.contact_request (request);

    /**
    * TODO: Handle errors.
    **/
    
  }
}
