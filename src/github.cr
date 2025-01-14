# Core and local requirements
require "http/client"
require "./session"
require "./user_repository"
require "./github/oauth"
require "./github/session_data"

# https://developer.github.com/apps/building-github-apps/identifying-and-authorizing-users-for-github-apps/
module GitHub
  extend self
  @@session = PrivPage2::Session(SessionData).new
  @@session.start_gc interval: 6.hour, max_period: 2.days

  def handle_request(first_subdomain_part, root_domain, context : HTTP::Server::Context)
    # Callback as the subdomain
    if first_subdomain_part == "callback"
      return handle_callback root_domain, context
    end

    # Remainder of valid requests
    if user_repository = PrivPage2::UserRepository.from_subdomain first_subdomain_part, context.response
      if session = @@session.get?(context.request.cookies["github_session"]?.try &.value)
        session.get_page user_repository, context.request.path, context.response
      else
        state = OAuth::State.new user_repository.subdomain, context.request.path
        OAuth.request_identity_redirect state, context.response
      end
    end
    # The response should have already been sent at this point
  end

  # Callback redirects to user/repo-specific subdomain
  def handle_callback(root_domain, context : HTTP::Server::Context)
    code : String? = nil
    state : OAuth::State? = nil
    if request_query = context.request.query
      HTTP::Params.parse request_query do |query, value|
        case query
        when "code" then code = value
        when "state"
          state = OAuth::State.from_string value
          # Invalid UserRepository - stop
          break if !state
        else
        end
      end
    end
    if !code || !state
      context.response.respond_with_status HTTP::Status::BAD_REQUEST
    else
      token = state.get_access_token code
      @@session.add state.random, SessionData.new(token)
      context.response.cookies << HTTP::Cookie.new(
        name: "github_session",
        domain: root_domain,
        value: state.random,
        http_only: true,
        secure: true,
      )
      full_path = "http://#{state.user_repository_subdomain}#{root_domain}#{state.path}"
      redirect full_path, context.response
    end
  end

  def redirect(path : String, response : HTTP::Server::Response)
    response.headers["location"] = path
    response << "Redirection: " << path
    response.status = HTTP::Status::TEMPORARY_REDIRECT
  end
end
