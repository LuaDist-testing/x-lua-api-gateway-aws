# vim:set ft= ts=4 sw=4 et fdm=marker:
use lib 'lib';
use strict;
use warnings;
use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

#worker_connections(1014);
#master_process_enabled(1);
#log_level('warn');

repeat_each(1);

plan tests => repeat_each() * (blocks() * 4)-2;

my $pwd = cwd();

# try to read the nameservers used by the system resolver:
my @nameservers;
if (open my $in, "/etc/resolv.conf") {
    while (<$in>) {
        if (/^\s*nameserver\s+(\d+(?:\.\d+){3})(?:\s+|$)/) {
            push @nameservers, $1;
            if (@nameservers > 10) {
                last;
            }
        }
    }
    close $in;
}

if (!@nameservers) {
    # default to Google's open DNS servers
    push @nameservers, "8.8.8.8", "8.8.4.4";
}


warn "Using nameservers: \n@nameservers\n";

our $HttpConfig = <<_EOC_;
    # lua_package_path "$pwd/scripts/?.lua;;";
    lua_package_path 'src/lua/?.lua;;';
    lua_package_cpath 'src/lua/?.so;;';
    init_by_lua '
        local v = require "jit.v"
        v.on("$Test::Nginx::Util::ErrLogFile")
        require "resty.core"
    ';
    resolver @nameservers;

    client_body_temp_path /tmp/;
    proxy_temp_path /tmp/;
    fastcgi_temp_path /tmp/;
_EOC_

#no_diff();
no_long_string();
run_tests();

__DATA__


=== TEST 1: test SNS
--- http_config eval: $::HttpConfig
--- config
        error_log ../sns_test1_error.log debug;

        location = /latest/meta-data/iam/security-credentials/ {
            return 200 'test-iam-user';
        }

        location = /latest/meta-data/iam/security-credentials/test-iam-user {
            return 200 '{
                          "Code" : "Success",
                          "LastUpdated" : "2014-11-03T01:56:20Z",
                          "Type" : "AWS-HMAC",
                          "AccessKeyId" : "$TEST_NGINX_AWS_CLIENT_ID",
                          "SecretAccessKey" : "$TEST_NGINX_AWS_SECRET",
                          "Token" : "$TEST_NGINX_AWS_SECURITY_TOKEN",
                          "Expiration" : "2014-11-03T08:07:52Z"
                        }';
        }

        location /test {
            set $aws_region us-east-1;
            set $aws_service sns;

            content_by_lua '
                local SnsService = require "api-gateway.aws.sns.SnsService"

                local service = SnsService:new({
                    security_credentials_host = "127.0.0.1",
                    security_credentials_port = $TEST_NGINX_PORT,
                    aws_region = ngx.var.aws_region,
                    aws_debug = true,              -- print warn level messages on the nginx logs
                    aws_conn_keepalive = 60000,    -- how long to keep the sockets used for AWS alive
                    aws_conn_pool = 100            -- the connection pool size for sockets used to connect to AWS
                })

                -- search for aliases
                local list  = service:listTopics()
                assert(list ~= nil, "ListTopics should return at least 1 topic")

                -- pick the first topic
                local topicArn = list.ListTopicsResponse.ListTopicsResult.Topics[1].TopicArn
                assert(topicArn ~= nil, "Topic not found.")
                ngx.say("TopicARN:" .. tostring(topicArn))

                local response = service:publish("test-subject","test-message-from-openresty-unit-test", topicArn)
                assert(response ~= nil, "Publish response should not be null")
                local messageId = response.PublishResponse.PublishResult.MessageId
                ngx.say("Message_ID:" .. tostring(messageId))
            ';
        }
--- request
GET /test
--- response_body_like eval
[".*TopicARN:arn:aws:sns:.*Message_ID:[a-zA-Z0-9]{8}-[a-zA-Z0-9]{4}-[a-zA-Z0-9]{4}-[a-zA-Z0-9]{4}-[a-zA-Z0-9]{12}"]
--- error_code: 200
--- no_error_log
[error]
--- more_headers
X-Test: test


=== TEST 2: test SNS with special chars in message
--- http_config eval: $::HttpConfig
--- config
        error_log ../sns_test2_error.log debug;

        location = /latest/meta-data/iam/security-credentials/ {
            return 200 'test-iam-user';
        }

        location = /latest/meta-data/iam/security-credentials/test-iam-user {
            return 200 '{
                          "Code" : "Success",
                          "LastUpdated" : "2014-11-03T01:56:20Z",
                          "Type" : "AWS-HMAC",
                          "AccessKeyId" : "$TEST_NGINX_AWS_CLIENT_ID",
                          "SecretAccessKey" : "$TEST_NGINX_AWS_SECRET",
                          "Token" : "$TEST_NGINX_AWS_SECURITY_TOKEN",
                          "Expiration" : "2014-11-03T08:07:52Z"
                        }';
        }

        location /test {
            set $aws_region us-east-1;
            set $aws_service sns;

            content_by_lua '
                local SnsService = require "api-gateway.aws.sns.SnsService"

                local service = SnsService:new({
                    security_credentials_host = "127.0.0.1",
                    security_credentials_port = $TEST_NGINX_PORT,
                    aws_region = ngx.var.aws_region,
                    aws_debug = true,              -- print warn level messages on the nginx logs
                    aws_conn_keepalive = 60000,    -- how long to keep the sockets used for AWS alive
                    aws_conn_pool = 100            -- the connection pool size for sockets used to connect to AWS
                })

                -- search for aliases
                local list  = service:listTopics()
                ngx.sleep(2)
                assert(list ~= nil, "ListTopics should return at least 1 topic")

                -- pick the first topic
                local topicArn = list.ListTopicsResponse.ListTopicsResult.Topics[1].TopicArn
                assert(topicArn ~= nil, "Topic not found.")
                ngx.say("TopicARN:" .. tostring(topicArn))

                -- AWS does not accept the following characters: * ( ) =
                -- AWS is buggy with the following characters:
                local special_chars = "`~1!2@3#4$56^7&890-_+{}[]\\"\\\\|:;<>,./?end"
                local response = service:publish("test-subject","test-message-from-openresty-unit-test-special-chars:" .. special_chars, topicArn)
                local messageId = response.PublishResponse.PublishResult.MessageId
                ngx.say("Message_ID:" .. tostring(messageId))
            ';
        }

--- timeout: 70
--- more_headers
X-Test: test
--- request
GET /test
--- response_body_like eval
[".*TopicARN:arn:aws:sns:.*Message_ID:[a-zA-Z0-9]{8}-[a-zA-Z0-9]{4}-[a-zA-Z0-9]{4}-[a-zA-Z0-9]{4}-[a-zA-Z0-9]{12}"]
--- error_code: 200
--- no_error_log
[error]



