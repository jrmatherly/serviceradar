defmodule ServiceRadarWebNGWeb.SAMLControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.SAMLConsumedAssertion
  alias ServiceRadar.Identity.SAMLPendingRequest
  alias ServiceRadar.Identity.User
  alias ServiceRadarWebNG.SAMLFixtures
  alias ServiceRadarWebNGWeb.Auth.ConfigCache
  alias ServiceRadarWebNGWeb.Auth.SAMLStrategy

  require Ash.Query

  @moduletag :web_ng_shared_fixture_db

  @sp_entity_id "https://sp.example.com"
  @browser_cookie "sr_saml_browser"
  # The value GET /auth/saml would have set in the posting browser.
  @browser_key "test-browser-key-00000"
  @invalid_request "Authentication failed: invalid request. Please try again."
  @failed "Authentication failed. Please try again."

  setup do
    maybe_start_config_cache()
    clear_auth_cache()

    idp = SAMLFixtures.idp()

    put_saml_settings(%{
      is_enabled: true,
      mode: :active_sso,
      provider_type: :saml,
      saml_idp_metadata_xml: SAMLFixtures.metadata(idp, sso_url: "https://127.0.0.1/sso"),
      saml_sp_entity_id: @sp_entity_id,
      claim_mappings: nil,
      saml_pinned_cert_fingerprints: nil
    })

    previous_idp_initiated = Application.get_env(:serviceradar_web_ng, :saml_allow_idp_initiated)

    on_exit(fn ->
      clear_auth_cache()
      Application.put_env(:serviceradar_web_ng, :saml_allow_idp_initiated, previous_idp_initiated)
    end)

    %{idp: idp}
  end

  test "rejects SAML login initiation when metadata-derived SSO URL violates outbound policy", %{
    conn: conn
  } do
    conn = get(conn, ~p"/auth/saml")

    assert redirected_to(conn) == ~p"/users/log-in"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "SAML authentication is not properly configured."
  end

  test "a cross-site POST with the browser cookie, no session cookie and no CSRF token signs in",
       %{idp: idp} do
    {email, user} = provision_saml_user()
    {relay_state, request_id} = open_pending_request()
    assertion_id = unique_id("_assertion")

    saml_response =
      signed_response(idp, email, assertion_id: assertion_id, in_response_to: request_id)

    conn = cross_site_post(%{"SAMLResponse" => saml_response, "RelayState" => relay_state})

    assert [{"cookie", "#{@browser_cookie}=#{@browser_key}"}] =
             conn.req_headers |> List.keytake("cookie", 0) |> elem(0) |> List.wrap()

    refute Map.has_key?(conn.body_params, "_csrf_token")
    assert redirected_to(conn) == ~p"/dashboard"
    assert get_session(conn, :live_socket_id) == "users_sessions:#{user.id}"
    assert Enum.count(recorded_assertion_ids(idp), &(&1 == assertion_id)) == 1

    # The pending request was spent by the login.
    assert {:ok, nil} =
             SAMLPendingRequest.take("#{relay_state}.#{@browser_key}",
               actor: SystemActor.system(:test)
             )
  end

  test "a valid response posted without the browser cookie is rejected", %{idp: idp} do
    {email, _user} = provision_saml_user()
    {relay_state, request_id} = open_pending_request()

    saml_response =
      signed_response(idp, email, assertion_id: unique_id("_assertion"), in_response_to: request_id)

    conn =
      cross_site_post(%{"SAMLResponse" => saml_response, "RelayState" => relay_state}, cookie: nil)

    assert_failed(conn, @invalid_request)
    refute get_session(conn, :live_socket_id)
    # Not spent: the right browser can still finish this login.
    assert {:ok, %SAMLPendingRequest{}} =
             SAMLPendingRequest.take("#{relay_state}.#{@browser_key}",
               actor: SystemActor.system(:test)
             )
  end

  test "a valid response posted from another browser is rejected", %{idp: idp} do
    {email, _user} = provision_saml_user()
    {relay_state, request_id} = open_pending_request()

    saml_response =
      signed_response(idp, email, assertion_id: unique_id("_assertion"), in_response_to: request_id)

    conn =
      cross_site_post(%{"SAMLResponse" => saml_response, "RelayState" => relay_state},
        cookie: "other-browser-key-0000"
      )

    assert_failed(conn, @invalid_request)
    refute get_session(conn, :live_socket_id)
  end

  test "two login tabs in one browser both sign in", %{idp: idp} do
    {email, user} = provision_saml_user()
    {first_relay_state, first_request_id} = open_pending_request()
    {second_relay_state, second_request_id} = open_pending_request()

    first =
      cross_site_post(%{
        "SAMLResponse" =>
          signed_response(idp, email,
            assertion_id: unique_id("_assertion"),
            in_response_to: first_request_id
          ),
        "RelayState" => first_relay_state
      })

    second =
      cross_site_post(%{
        "SAMLResponse" =>
          signed_response(idp, email,
            assertion_id: unique_id("_assertion"),
            in_response_to: second_request_id
          ),
        "RelayState" => second_relay_state
      })

    assert redirected_to(first) == ~p"/dashboard"
    assert redirected_to(second) == ~p"/dashboard"
    assert get_session(first, :live_socket_id) == "users_sessions:#{user.id}"
    assert get_session(second, :live_socket_id) == "users_sessions:#{user.id}"
  end

  test "a login started in one browser finishes only with that browser's cookie", %{
    conn: conn,
    idp: idp
  } do
    # The outbound policy resolves hostnames, so the SSO URL is the literal public
    # address the policy's own tests accept.
    clear_auth_cache()

    put_saml_settings(%{
      is_enabled: true,
      mode: :active_sso,
      provider_type: :saml,
      saml_idp_metadata_xml: SAMLFixtures.metadata(idp, sso_url: "https://1.1.1.1/sso"),
      saml_sp_entity_id: @sp_entity_id,
      claim_mappings: nil,
      saml_pinned_cert_fingerprints: nil
    })

    {email, user} = provision_saml_user()
    started = get(conn, ~p"/auth/saml")

    assert %{value: key, http_only: true, secure: true, same_site: "None", path: "/auth/saml"} =
             started.resp_cookies[@browser_cookie]

    assert byte_size(key) == 22

    %{"RelayState" => relay_state, "SAMLRequest" => saml_request} =
      started |> redirected_to(302) |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    [_, request_id] =
      Regex.run(~r/ ID="([^"]+)"/, saml_request |> Base.decode64!() |> :zlib.unzip())

    params = %{
      "SAMLResponse" => signed_response(idp, email, assertion_id: unique_id("_assertion"), in_response_to: request_id),
      "RelayState" => relay_state
    }

    assert_failed(cross_site_post(params, cookie: nil), @invalid_request)
    assert_failed(cross_site_post(params, cookie: "other-browser-key-0000"), @invalid_request)

    conn = cross_site_post(params, cookie: key)
    assert redirected_to(conn) == ~p"/dashboard"
    assert get_session(conn, :live_socket_id) == "users_sessions:#{user.id}"
  end

  test "the same cross-site request is refused by a CSRF-protected browser route" do
    # Proves the harness above really omits the CSRF token: the :browser
    # pipeline the ACS used to share answers it with 403.
    assert_error_sent 403, fn ->
      cross_site_post(%{"user" => %{"email" => "someone@example.com"}}, path: ~p"/auth/sign-in")
    end
  end

  test "rejects a RelayState that was already used", %{idp: idp} do
    {email, user} = provision_saml_user()
    {relay_state, request_id} = open_pending_request()

    first =
      cross_site_post(%{
        "SAMLResponse" => signed_response(idp, email, in_response_to: request_id),
        "RelayState" => relay_state
      })

    assert get_session(first, :live_socket_id) == "users_sessions:#{user.id}"

    # A fresh, valid response for the same request, on the spent RelayState.
    second_assertion_id = unique_id("_assertion")

    second =
      cross_site_post(%{
        "SAMLResponse" => signed_response(idp, email, assertion_id: second_assertion_id, in_response_to: request_id),
        "RelayState" => relay_state
      })

    assert_failed(second, @invalid_request)
    refute second_assertion_id in recorded_assertion_ids(idp)
  end

  test "rejects a RelayState that was never issued", %{idp: idp} do
    {email, _user} = provision_saml_user()
    {_relay_state, request_id} = open_pending_request()

    conn =
      cross_site_post(%{
        "SAMLResponse" => signed_response(idp, email, in_response_to: request_id),
        "RelayState" => random_relay_state()
      })

    assert_failed(conn, @invalid_request)
  end

  test "rejects an expired pending request and spends it", %{idp: idp} do
    {email, _user} = provision_saml_user()
    {relay_state, request_id} = open_pending_request(expires_in: -60)

    {conn, log} =
      with_log(fn ->
        cross_site_post(%{
          "SAMLResponse" => signed_response(idp, email, in_response_to: request_id),
          "RelayState" => relay_state
        })
      end)

    assert_failed(conn, @invalid_request)
    assert log =~ ":authn_request_expired"
    assert {:ok, nil} = SAMLPendingRequest.take(relay_state, actor: SystemActor.system(:test))
  end

  test "rejects a response for one request posted with another request's RelayState", %{idp: idp} do
    {email, _user} = provision_saml_user()
    {_other_relay_state, other_request_id} = open_pending_request()

    for {in_response_to, reason} <- [
          {other_request_id, ":in_response_to_mismatch"},
          {nil, ":missing_in_response_to"}
        ] do
      {relay_state, _request_id} = open_pending_request()
      assertion_id = unique_id("_assertion")

      saml_response =
        signed_response(idp, email, assertion_id: assertion_id, in_response_to: in_response_to)

      {conn, log} =
        with_log(fn ->
          cross_site_post(%{"SAMLResponse" => saml_response, "RelayState" => relay_state})
        end)

      assert_failed(conn, @failed)
      assert log =~ reason
      # Rejected before the replay ledger, so the assertion was never spent.
      refute assertion_id in recorded_assertion_ids(idp)
    end
  end

  test "the replay ledger rejects an assertion even when the request binding matches", %{idp: idp} do
    {email, user} = provision_saml_user()
    request_id = unique_id("_req")
    {first_relay_state, _} = open_pending_request(request_id: request_id)
    {second_relay_state, _} = open_pending_request(request_id: request_id)
    saml_response = signed_response(idp, email, in_response_to: request_id)

    first = cross_site_post(%{"SAMLResponse" => saml_response, "RelayState" => first_relay_state})
    assert get_session(first, :live_socket_id) == "users_sessions:#{user.id}"

    {replay, log} =
      with_log(fn ->
        cross_site_post(%{"SAMLResponse" => saml_response, "RelayState" => second_relay_state})
      end)

    assert_failed(replay, @failed)
    assert log =~ ":assertion_replayed"
  end

  test "rejects an unsolicited response by default", %{idp: idp} do
    {email, _user} = provision_saml_user()
    assertion_id = unique_id("_assertion")

    conn =
      cross_site_post(%{"SAMLResponse" => signed_response(idp, email, assertion_id: assertion_id)})

    assert_failed(conn, @invalid_request)
    refute assertion_id in recorded_assertion_ids(idp)
  end

  test "accepts an unsolicited response once when IdP-initiated login is enabled", %{idp: idp} do
    Application.put_env(:serviceradar_web_ng, :saml_allow_idp_initiated, true)
    {email, user} = provision_saml_user()
    saml_response = signed_response(idp, email)

    conn = cross_site_post(%{"SAMLResponse" => saml_response})
    assert redirected_to(conn) == ~p"/dashboard"
    assert get_session(conn, :live_socket_id) == "users_sessions:#{user.id}"

    replay = cross_site_post(%{"SAMLResponse" => saml_response})
    assert_failed(replay, @failed)

    # An unsolicited response may not claim to answer some request.
    bound = signed_response(idp, email, in_response_to: unique_id("_req"))

    conn = cross_site_post(%{"SAMLResponse" => bound, "RelayState" => random_relay_state()})
    assert_failed(conn, @failed)
  end

  test "redirects only to the same-origin path stored when the login started", %{idp: idp} do
    {email, _user} = provision_saml_user()

    for {stored, expected} <- [{"/devices", "/devices"}, {"//evil.example.com/x", "/dashboard"}] do
      {relay_state, request_id} = open_pending_request(return_to: stored)

      conn =
        cross_site_post(%{
          "SAMLResponse" => signed_response(idp, email, in_response_to: request_id),
          "RelayState" => relay_state,
          "return_to" => "https://evil.example.com/"
        })

      assert redirected_to(conn) == expected
    end
  end

  test "rejects SAML ACS XML with external entities" do
    {relay_state, _request_id} = open_pending_request()

    malicious_response =
      Base.encode64("""
      <!DOCTYPE samlp:Response [
        <!ENTITY xxe SYSTEM "file:///etc/passwd">
      ]>
      <samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol">
        <saml:Assertion xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion">
          <saml:Issuer>&xxe;</saml:Issuer>
        </saml:Assertion>
      </samlp:Response>
      """)

    conn = cross_site_post(%{"SAMLResponse" => malicious_response, "RelayState" => relay_state})

    assert_failed(conn, @failed)
  end

  # A request the way an IdP's auto-submitting form sends it: no session cookie
  # and no Phoenix CSRF token. Phoenix.ConnTest marks its connections to skip
  # CSRF checks; removing that mark makes the pipeline enforce them.
  defp cross_site_post(params, opts \\ []) do
    path = Keyword.get(opts, :path, ~p"/auth/saml/consume")

    conn = Map.update!(build_conn(), :private, &Map.delete(&1, :plug_skip_csrf_protection))

    conn =
      case Keyword.get(opts, :cookie, @browser_key) do
        nil -> conn
        cookie -> put_req_cookie(conn, @browser_cookie, cookie)
      end

    post(conn, path, params)
  end

  # What `GET /auth/saml` stores for an SP-initiated login. The GET itself is
  # not exercised here: its redirect needs an SSO URL the outbound URL policy
  # accepts, and every documentation-range host is refused.
  defp open_pending_request(opts \\ []) do
    relay_state = random_relay_state()
    request_id = Keyword.get_lazy(opts, :request_id, fn -> unique_id("_req") end)
    expires_at = DateTime.shift(DateTime.utc_now(), second: Keyword.get(opts, :expires_in, 600))

    {:ok, _pending} =
      SAMLPendingRequest.open(
        "#{relay_state}.#{@browser_key}",
        request_id,
        expires_at,
        %{return_to: Keyword.get(opts, :return_to)},
        actor: SystemActor.system(:test)
      )

    {relay_state, request_id}
  end

  defp signed_response(idp, email, opts \\ []) do
    SAMLFixtures.response(
      idp,
      Keyword.merge([name_id: email, email: email, recipient: SAMLStrategy.get_acs_url()], opts)
    )
  end

  defp assert_failed(conn, message) do
    assert redirected_to(conn) == ~p"/users/log-in"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == message
    refute get_session(conn, "user_token")
  end

  # A pre-provisioned SSO account, found by external_id (the NameID) so the
  # test does not depend on JIT provisioning settings.
  defp provision_saml_user do
    email = "saml-#{System.unique_integer([:positive])}@example.com"

    {:ok, user} =
      User.provision_sso_user(
        %{email: email, display_name: "SAML User", external_id: email, provider: :saml},
        actor: SystemActor.system(:test)
      )

    {email, user}
  end

  defp recorded_assertion_ids(idp) do
    SAMLConsumedAssertion
    |> Ash.Query.filter(issuer == ^idp.entity_id)
    |> Ash.read!(actor: SystemActor.system(:test))
    |> Enum.map(& &1.assertion_id)
  end

  defp random_relay_state, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp maybe_start_config_cache do
    case Process.whereis(ConfigCache) do
      nil -> start_supervised!({ConfigCache, ttl_ms: 60_000})
      _pid -> :ok
    end
  end

  defp clear_auth_cache do
    if :ets.whereis(ConfigCache) != :undefined do
      :ets.delete(ConfigCache, :auth_settings)
      ConfigCache.clear_cache()
    end
  end

  defp put_saml_settings(settings) when is_map(settings) do
    expires_at = System.monotonic_time(:millisecond) + to_timeout(minute: 5)
    :ets.insert(ConfigCache, {:auth_settings, settings, expires_at})
  end
end
