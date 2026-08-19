require "rails_helper"
require "gds_api/test_helpers/asset_manager"

describe "assets resource" do
  include ActiveSupport::Testing::TimeHelpers
  include GdsApi::TestHelpers::AssetManager

  let(:parsed_response) { JSON.parse(response.body).deep_symbolize_keys }
  shared_examples "includes a draft response token" do
    it "generates and includes a token in the file_url" do
      expected_decoded_token = {
        "exp" => Time.zone.local(2026, 1, 31, 0, 0, 1).to_i,
        "iat" => Time.zone.now.to_i,
        "sub" => "token",
      }

      expect(decoded_token_payload_from_url(parsed_response[:file_url])).to eq(expected_decoded_token)
    end

    it "includes a preview expiry date 30 days in the future" do
      expect(parsed_response).to include(preview_expiry: Time.zone.local(2026, 1, 31, 0, 0, 1).iso8601)
    end
  end

  shared_examples "passes request params to Asset Manager" do
    it "preserves the request params" do
      expected_params = request_params.fetch(:asset).dup
      expected_params[:file] = anything if expected_params.key?(:file)

      expect(Services.asset_manager).to have_received(:update_asset).with("123456789", hash_including(expected_params))
    end
  end

  describe "GET /assets/:id" do
    let(:asset_manager_response) do
      {
        _response_info: {
          status: "ok",
        },
        content_type: "text",
        deleted: "false",
        draft: "false",
        file_url: "http://asset-manager.dev.gov.uk/media/123456789/asset.txt",
        id: "http://asset-manager/assets/123456789",
        name: "asset.txt",
        size: "12",
        state: "clean",
      }
    end

    subject do
      get "/assets/123456789"
    end

    context "when Asset Manager responds with ok" do
      before do
        allow(Services.asset_manager).to receive(:asset).and_return(asset_manager_response.deep_stringify_keys)

        subject
      end

      it "responds with 200 OK" do
        expect(response).to have_http_status(:ok)
      end

      it "responds with data from Asset Manager" do
        expect(parsed_response).to include(asset_manager_response)
        expect(parsed_response).to include(asset_id: "123456789")
      end
    end

    context "when Asset Manager responds with GdsApi::HTTPNotFound" do
      before do
        allow(Services.asset_manager).to receive(:asset).and_raise(GdsApi::HTTPNotFound.new(404))

        subject
      end

      it "responds with 404 Not Found" do
        expect(response).to have_http_status(:not_found)
        expect(response.body).to include("Asset not found")
      end
    end

    context "when Asset Manager responds with GdsApi::HTTPForbidden" do
      before do
        allow(Services.asset_manager).to receive(:asset).and_raise(GdsApi::HTTPForbidden.new(403))

        subject
      end

      it "responds with 403 Forbidden" do
        expect(response).to have_http_status(:forbidden)
        expect(response.body).to include("Access to asset is forbidden")
      end
    end
  end

  describe "POST /assets" do
    let(:draft) { true }
    let(:asset_manager_response) do
      {
        _response_info: {
          status: "ok",
        },
        content_type: "text",
        deleted: "false",
        draft: draft.to_s,
        file_url: "http://asset-manager.dev.gov.uk/media/45678/asset.txt",
        id: "123",
        name: "asset.txt",
        size: "12",
        state: "clean",
      }
    end

    subject do
      post_multipart "/assets", {
        asset: {
          file: fixture_file_upload("asset.txt", "text/plain"),
        },
      }
    end

    context "when Asset Manager responds with ok" do
      before do
        allow(Services.asset_manager).to receive(:create_asset).and_return(asset_manager_response.deep_stringify_keys)
      end

      context "when the request marks the asset as live" do
        let(:draft) { false }

        subject do
          post_multipart "/assets", {
            asset: {
              file: fixture_file_upload("asset.txt", "text/plain"),
              draft: false,
            },
          }
        end

        before do
          subject
        end

        it "responds with 201 Created" do
          expect(response).to have_http_status(:created)
        end

        it "responds with data from Asset Manager" do
          expect(parsed_response).to include(asset_manager_response)
          expect(parsed_response).to include(asset_id: "45678")
        end

        it "does not include a token in the file_url" do
          expect(parsed_response[:file_url]).not_to match(/token=/)
        end
      end

      context "when the request marks the asset as draft" do
        before do
          allow(SecureRandom).to receive(:uuid).and_return("token")
          travel_to Time.zone.local(2026, 1, 1, 0, 0, 1)

          subject
        end

        it "responds with 201 Created" do
          expect(response).to have_http_status(:created)
        end

        it "responds with data from Asset Manager" do
          expect(parsed_response).to include(asset_manager_response.except(:file_url))
          expect(parsed_response).to include(asset_id: "45678")
        end

        it_behaves_like "includes a draft response token"
      end
    end

    context "when Asset Manager responds with GdsApi::HTTPPayloadTooLarge" do
      before do
        allow(Services.asset_manager).to receive(:create_asset).and_raise(GdsApi::HTTPPayloadTooLarge.new(413))

        subject
      end

      it "responds with 413 Content Too Large" do
        expect(response).to have_http_status(:content_too_large)
        expect(response.body).to include("Content exceeds maximum permitted size")
      end
    end

    context "when Asset Manager responds with GdsApi::HTTPUnprocessableEntity" do
      before do
        allow(Services.asset_manager).to receive(:create_asset).and_raise(GdsApi::HTTPUnprocessableEntity.new(422, "Some error message"))

        subject
      end

      it "responds with 422 Unprocessable Entity" do
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("Some error message")
      end
    end

    context "when the Accept header is not application/json" do
      subject do
        post_multipart "/assets", {
          asset: {
            file: fixture_file_upload("asset.txt", "text/plain"),
          },
        }, { "HTTP_ACCEPT" => "text/plain" }
      end

      before do
        allow(Services.asset_manager).to receive(:create_asset).and_return(asset_manager_response.deep_stringify_keys)

        subject
      end

      it "responds with a 406 Not Acceptable" do
        expect(response).to have_http_status(:not_acceptable)
      end
    end

    context "when Content-Type header is not multipart/form-data" do
      subject do
        post "/assets", params: {}, headers: {
          "CONTENT_TYPE" => "application/json",
          "HTTP_ACCEPT" => "application/json",
          "HTTP_AUTHORIZATION" => "Bearer 12345678",
        }
      end

      before do
        subject
      end

      it "responds with 415 Unsupported Media Type" do
        expect(response).to have_http_status(:unsupported_media_type)
      end
    end
  end

  describe "PUT /assets/:id" do
    let(:draft) { true }
    let(:additional_attributes) { {} }
    let(:request_params) { { asset: { file: fixture_file_upload("asset.txt", "text/plain") } } }
    let(:asset_manager_response) do
      {
        _response_info: {
          status: "ok",
        },
        content_type: "text",
        deleted: "false",
        draft: draft.to_s,
        file_url: "http://asset-manager.dev.gov.uk/media/123456789/asset.txt",
        id: "http://asset-manager/assets/123456789",
        name: "asset.txt",
        size: "12",
        state: "clean",
      }.merge(additional_attributes)
    end

    subject do
      put_multipart "/assets/123456789", request_params
    end

    context "when Asset Manager responds with ok" do
      before do
        allow(Services.asset_manager).to receive(:update_asset).and_call_original
        stub_asset_manager_update_asset("123456789", asset_manager_response.deep_stringify_keys)
      end

      context "when the request includes a new file" do
        before do
          subject
        end

        it "responds with 200 OK" do
          expect(response).to have_http_status(:ok)
        end

        it "responds with data from Asset Manager" do
          expect(parsed_response).to include(asset_id: "123456789")
        end

        it_behaves_like "passes request params to Asset Manager"
      end

      context "when the client provides a value for draft" do
        let(:request_params) { { asset: { draft: draft, file: fixture_file_upload("asset.txt", "text/plain") } } }

        context "when the asset is not draft" do
          let(:draft) { false }

          before do
            subject
          end

          it "responds with 200 OK" do
            expect(response).to have_http_status(:ok)
          end

          it "responds with data from Asset Manager" do
            expect(parsed_response).to include(asset_manager_response)
            expect(parsed_response).to include(asset_id: "123456789")
          end

          it "does not include a token in the file_url" do
            expect(parsed_response[:file_url]).not_to match(/token=/)
          end

          it_behaves_like "passes request params to Asset Manager"
        end

        context "when the asset is draft" do
          before do
            allow(SecureRandom).to receive(:uuid).and_return("token")
            travel_to Time.zone.local(2026, 1, 1, 0, 0, 1)

            subject
          end

          before do
            subject
          end

          it "responds with 200 OK" do
            expect(response).to have_http_status(:ok)
          end

          it "responds with data from Asset Manager" do
            expect(parsed_response).to include(asset_manager_response.except(:file_url))
            expect(parsed_response).to include(asset_id: "123456789")
          end

          it_behaves_like "passes request params to Asset Manager"

          it_behaves_like "includes a draft response token"
        end
      end

      context "when request params includes a replacement_id" do
        let(:additional_attributes) { { replacement_id: "987654321" } }
        let(:request_params) { { asset: additional_attributes } }

        before do
          subject
        end

        it "responds with 200 OK" do
          expect(response).to have_http_status(:ok)
        end

        it "responds with data from Asset Manager" do
          expect(parsed_response).to include(asset_id: "123456789")
        end

        it "includes the replacement_id in the response" do
          expect(parsed_response).to include(replacement_id: "987654321")
        end

        it_behaves_like "passes request params to Asset Manager"
      end
    end

    context "when Asset Manager responds with GdsApi::HTTPPayloadTooLarge" do
      before do
        stub_asset_manager_responds_payload_too_large

        subject
      end

      it "returns with 413 Content Too Large" do
        expect(response).to have_http_status(:content_too_large)
        expect(response.body).to include("Content exceeds maximum permitted size")
      end
    end

    context "when Asset Manager responds with GdsApi::HTTPNotFound" do
      before do
        stub_asset_manager_does_not_have_an_asset("123456789")

        subject
      end

      it "returns with 404 Not Found" do
        expect(response).to have_http_status(:not_found)
        expect(response.body).to include("Asset does not exist")
      end
    end

    context "when Asset Manager responds with GdsApi::HTTPForbidden" do
      before do
        stub_asset_manager_responds_forbidden("123456789")

        subject
      end

      it "returns with 403 Forbidden" do
        expect(response).to have_http_status(:forbidden)
        expect(response.body).to include("Access to asset is forbidden")
      end
    end

    context "when Asset Manager responds with GdsApi::HTTPUnprocessableEntity" do
      before do
        stub_asset_manager_responds_unprocessable

        subject
      end

      it "returns with 422 Unprocessable Entity" do
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("Asset update failed")
      end
    end

    context "when the Accept header is not application/json" do
      subject do
        put_multipart "/assets/12345", request_params, { "HTTP_ACCEPT" => "text/plain" }
      end

      before do
        allow(Services.asset_manager).to receive(:update_asset).and_return(asset_manager_response.deep_stringify_keys)

        subject
      end

      it "responds with 406 Not Acceptable" do
        expect(response).to have_http_status(:not_acceptable)
      end
    end

    context "when the content type header is not multipart/form-data" do
      subject do
        put "/assets/12345", params: {}, headers: {
          "CONTENT_TYPE" => "application/json",
          "HTTP_ACCEPT" => "application/json",
          "HTTP_AUTHORIZATION" => "Bearer 12345678",
        }
      end

      before do
        subject
      end

      it "responds with 415 Unsupported Media Type" do
        expect(response).to have_http_status(:unsupported_media_type)
      end
    end
  end

  describe "POST /assets/:id/regenerate-access" do
    let(:asset_manager_response) do
      {
        _response_info: {
          status: "ok",
        },
        content_type: "text",
        deleted: "false",
        draft: "false",
        file_url: "http://asset-manager.dev.gov.uk/media/123456789/asset.txt",
        id: "http://asset-manager/assets/123456789",
        name: "asset.txt",
        size: "12",
        state: "clean",
      }
    end

    subject do
      post "/assets/123456789/regenerate-access"
    end

    context "when Asset Manager responds with ok" do
      before do
        allow(Services.asset_manager).to receive(:update_asset).and_return(asset_manager_response.deep_stringify_keys)
        allow(SecureRandom).to receive(:uuid).and_return("token")
        travel_to Time.zone.local(2026, 1, 1, 0, 0, 1)

        subject
      end

      it "responds with 201 Created" do
        expect(response).to have_http_status(:created)
      end

      it "responds with data from Asset Manager" do
        expect(parsed_response).to include(asset_manager_response.except(:file_url))
      end

      it_behaves_like "includes a draft response token"
    end

    context "when Asset Manager responds with GdsApi::HTTPNotFound" do
      before do
        allow(Services.asset_manager).to receive(:update_asset).and_raise(GdsApi::HTTPNotFound.new(404))

        subject
      end

      it "responds with 404 Not Found" do
        expect(response).to have_http_status(:not_found)
        expect(response.body).to include("Asset not found")
      end
    end

    context "when Asset Manager responds with GdsApi::HTTPForbidden" do
      before do
        allow(Services.asset_manager).to receive(:update_asset).and_raise(GdsApi::HTTPForbidden.new(403))

        subject
      end

      it "responds with 403 Forbidden" do
        expect(response).to have_http_status(:forbidden)
        expect(response.body).to include("Access to asset is forbidden")
      end
    end
  end
end

def decoded_token_payload_from_url(url)
  query_params = Rack::Utils.parse_query(URI(url).query)

  payload, _header = JWT.decode(
    query_params["token"],
    Rails.application.config.jwt_auth_secret,
    true,
    { algorithm: "HS256" },
  )

  payload
end
