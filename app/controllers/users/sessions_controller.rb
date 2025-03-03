# frozen_string_literal: true

class Users::SessionsController < Devise::SessionsController
  layout :session_layout

  after_action :after_sign_in, only: %i(create authenticate_with_two_factor)
  before_action :remove_authenticate_mesasge_if_root_path, only: :new
  prepend_before_action :redirect_2fa, only: :create

  rescue_from ActionController::InvalidAuthenticityToken do
    redirect_to new_user_session_path
  end

  # GET /resource/sign_in
  def new
    @simple_sign_in = params[:simple_sign_in] == 'true'
    # If user was redirected here from OAuth's authorize/new page (Doorkeeper
    # endpoint for authorizing an OAuth client), 3rd party sign-in buttons
    # (e.g. LinkedIn) should be hidden. See config/initializers/devise.rb.
    @oauth_authorize = session['oauth_authorize'] == true
    super
  end

  # POST /resource/sign_in
  def create
    super

    generate_templates_project
  end

  def two_factor_recovery
    unless session[:otp_user_id]
      redirect_to new_user_session_path
    end
  end

  # DELETE /resource/sign_out
  # def destroy
  #   super
  # end

  def after_sign_in
    flash[:system_notification_modal] = true
  end

  def authenticate_with_two_factor
    user = User.find_by(id: session[:otp_user_id])

    unless user
      flash[:alert] = t('devise.sessions.2fa.no_user_error')
      redirect_to root_path && return
    end

    if user.valid_otp?(params[:otp])
      session.delete(:otp_user_id)

      sign_in(user)
      generate_templates_project
      flash[:notice] = t('devise.sessions.signed_in')
      redirect_to stored_location_for(:user) || root_path
    else
      flash.now[:alert] = t('devise.sessions.2fa.error_message')
      render :two_factor_auth
    end
  end

  def authenticate_with_recovery_code
    user = User.find_by(id: session[:otp_user_id])

    unless user
      flash[:alert] = t('devise.sessions.2fa.no_user_error')
      redirect_to root_path && return
    end

    session.delete(:otp_user_id)
    if user.recover_2fa!(params[:recovery_code])
      sign_in(user)
      generate_templates_project
      flash[:notice] = t('devise.sessions.signed_in')
      redirect_to root_path
    else
      flash[:alert] = t("devise.sessions.2fa_recovery.not_correct_code")
      redirect_to new_user_session_path
    end

  end

  private

  def remove_authenticate_mesasge_if_root_path
    if session[:user_return_to] == root_path && flash[:alert] == I18n.t('devise.failure.unauthenticated')
      flash[:alert] = nil
    end
  end

  def redirect_2fa
    user = User.find_by(email: params[:user][:email])

    return unless user&.valid_password?(params[:user][:password])

    if user&.two_factor_auth_enabled?
      session[:otp_user_id] = user.id
      store_location_for(:user, request.original_fullpath) if request.get?
      render :two_factor_auth
    end
  end

  def generate_templates_project
    # Schedule templates creation for user
    TemplatesService.new.schedule_creation_for_user(current_user)
  rescue StandardError => e
    Rails.logger.fatal("User ID #{current_user.id}: Error creating inital projects on sign_in: #{e.message}")
  end

  def session_layout
    if @simple_sign_in
      'sign_in_halt'
    else
      'layouts/main'
    end
  end
end
