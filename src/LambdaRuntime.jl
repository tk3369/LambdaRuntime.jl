module LambdaRuntime

using HTTP
using JSON

const AWS_LAMBDA_RUNTIME_API = get(ENV, "AWS_LAMBDA_RUNTIME_API", "")
const LAMBDA_TASK_ROOT = get(ENV, "LAMBDA_TASK_ROOT", "")
const HANDLER = Symbol(get(ENV, "_HANDLER", "handle_event"))
const RUNTIME_URL = "http://$AWS_LAMBDA_RUNTIME_API/2018-06-01"

function __init__()
    @info "Initializing lambda"
    @info "Settings" AWS_LAMBDA_RUNTIME_API LAMBDA_TASK_ROOT HANDLER
end

function post_error(path::AbstractString, ex::Exception)
    headers = [
        "Content-type" => "application/json",
        "Lambda-Runtime-Function-Error-Type" => "Unhandled",
    ]
    body = JSON.json(Dict(
        "errorType" => string(typeof(ex)),
        "errorMessage" => string(ex)
    ))
    local url
    try
        url = "$RUNTIME_URL/$path"
        HTTP.post(url, headers, JSON.json(body))
        @info "Notified lambda runtime about the error" url ex
    catch failure
        @error "Unable to notify lambda runtime about the error" url ex failure
    end
end

function init(mod::Module)
    try
        # TODO
    catch ex
        @error "Initializtion error" ex
        post_error("runtime/init/error", ex)
        @info "Shutting down container"
        exit(1)
    end
end

function main_loop(mod::Module)
    @info "Start processing requests"
    while true
        local state, request, request_id
        try
            state = :start
            request = HTTP.get("$RUNTIME_URL/runtime/invocation/next")
            request_id = Dict(request.headers)["Lambda-Runtime-Aws-Request-Id"]
            @info "Received event" request_id
            state = :received

            response = @eval $(mod).$(HANDLER)(String($request.body), $request.headers)
            @info "Got response from handler" response
            state = :handled

            HTTP.post("$RUNTIME_URL/runtime/invocation/$request_id/response", [], response)
            @info "notified lambda runtime"
            state = :finished
        catch ex
            if state == :start
                @error "Unable to receive request" ex
            elseif state == :received
                @error "Unable to handle event" ex request
                post_error("runtime/invocation/$request_id/error", ex)
            elseif state == :handled
                @error "Unable to notify lambda runtime (invocation response)" ex request
            else
                @error "Unknown state" ex state
            end
            sleep(0.2)
        end
    end
    @info "Shutdown complete"
    exit(0)
end

end
