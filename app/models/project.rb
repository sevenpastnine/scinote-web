class Project < ApplicationRecord
  include ArchivableModel
  include SearchableModel
  include SearchableByNameModel
  include ViewableModel

  enum visibility: { hidden: 0, visible: 1 }

  auto_strip_attributes :name, nullify: false
  validates :name,
            length: { minimum: Constants::NAME_MIN_LENGTH,
                      maximum: Constants::NAME_MAX_LENGTH },
            uniqueness: { scope: :team_id, case_sensitive: false }
  validates :visibility, presence: true
  validates :team, presence: true
  validate :project_folder_team, if: -> { project_folder.present? }
  before_validation :remove_project_folder, on: :update, if: :archived_changed?

  belongs_to :created_by,
             foreign_key: 'created_by_id',
             class_name: 'User',
             optional: true
  belongs_to :last_modified_by,
             foreign_key: 'last_modified_by_id',
             class_name: 'User',
             optional: true
  belongs_to :archived_by,
             foreign_key: 'archived_by_id',
             class_name: 'User',
             optional: true
  belongs_to :restored_by,
             foreign_key: 'restored_by_id',
             class_name: 'User',
             optional: true
  belongs_to :team, inverse_of: :projects, touch: true
  belongs_to :project_folder, inverse_of: :projects, optional: true, touch: true
  has_many :user_projects, inverse_of: :project
  has_many :users, through: :user_projects
  has_many :experiments, inverse_of: :project
  has_many :active_experiments, -> { where(archived: false) },
           class_name: 'Experiment'
  has_many :project_comments, foreign_key: :associated_id, dependent: :destroy
  has_many :activities, inverse_of: :project
  has_many :tags, inverse_of: :project
  has_many :reports, inverse_of: :project, dependent: :destroy
  has_many :report_elements, inverse_of: :project, dependent: :destroy

  scope :visible_to, (lambda do |user, team|
                        unless user.is_admin_of_team?(team)
                          left_outer_joins(:user_projects)
                          .where('visibility = 1 OR user_projects.user_id = :id', id: user.id)
                          .group(:id)
                        end
                      end)

  scope :templates, -> { where(template: true) }

  def self.visible_from_user_by_name(user, team, name)
    projects = where(team: team).distinct
    if user.is_admin_of_team?(team)
      projects.where('projects.archived IS FALSE AND projects.name ILIKE ?', "%#{name}%")
    else
      projects.joins(:user_projects)
              .where('user_projects.user_id = ? OR projects.visibility = 1', user.id)
              .where('projects.archived IS FALSE AND projects.name ILIKE ?',
                     "%#{name}%")
    end
  end

  def self.search(
    user,
    include_archived,
    query = nil,
    page = 1,
    current_team = nil,
    options = {}
  )

    if current_team
      new_query =
        Project
        .distinct
        .joins(:user_projects)
        .where('projects.team_id = ?', current_team.id)
      unless user.user_teams.find_by(team: current_team).try(:admin?)
        # Admins see all projects in the team
        new_query = new_query.where(
          'projects.visibility = 1 OR user_projects.user_id = ?',
          user.id
        )
      end
      new_query = new_query.where_attributes_like(:name, query, options)

      if include_archived
        return new_query
      else
        return new_query.where('projects.archived = ?', false)
      end
    else
      new_query = Project
                  .distinct
                  .joins(team: :user_teams)
                  .where('user_teams.user_id = ?', user.id)

      if include_archived
        new_query =
          new_query
          .joins(:user_projects)
          .where(
            'user_teams.role = 2 OR projects.visibility = 1 OR ' \
            'user_projects.user_id = ?',
            user.id
          )
          .where_attributes_like('projects.name', query, options)

      else
        new_query =
          new_query
          .joins(:user_projects)
          .where(
            'user_teams.role = 2 OR projects.visibility = 1 OR ' \
            'user_projects.user_id = ?',
            user.id
          )
          .where_attributes_like('projects.name', query, options)
          .where('projects.archived = ?', false)
      end
    end

    # Show all results if needed
    if page == Constants::SEARCH_NO_LIMIT
      new_query
    else
      new_query
        .limit(Constants::SEARCH_LIMIT)
        .offset((page - 1) * Constants::SEARCH_LIMIT)
    end
  end

  def self.viewable_by_user(user, teams)
    # Admins see all projects in the team
    # Member of the projects can view
    # If project is visible everyone from the team can view it
    Project.where(team: teams)
           .left_outer_joins(team: :user_teams)
           .left_outer_joins(:user_projects)
           .where('projects.visibility = 1 OR '\
                  'user_projects.user_id = :user_id OR '\
                  '(user_teams.user_id = :user_id AND user_teams.role = 2)',
                  user_id: user.id)
           .distinct
  end

  def default_view_state
    {
      experiments: {
        active: { sort: 'new' },
        archived: { sort: 'new' },
        view_type: 'cards'
      }
    }
  end

  def validate_view_state(view_state)
    if %w(cards table).exclude?(view_state.state.dig('experiments', 'view_type')) ||
       %w(new old atoz ztoa).exclude?(view_state.state.dig('experiments', 'active', 'sort')) ||
       %w(new old atoz ztoa archived_new archived_old).exclude?(view_state.state.dig('experiments', 'archived', 'sort'))
      view_state.errors.add(:state, :wrong_state)
    end
  end

  def last_activities(count = Constants::ACTIVITY_AND_NOTIF_SEARCH_LIMIT)
    activities.order(created_at: :desc).first(count)
  end

  # Get project comments order by created_at time. Results are paginated
  # using last comment id and per_page parameters.
  def last_comments(last_id = 1, per_page = Constants::COMMENTS_SEARCH_LIMIT)
    last_id = Constants::INFINITY if last_id <= 1
    comments = ProjectComment.joins(:project)
                             .where(projects: { id: id })
                             .where('comments.id <  ?', last_id)
                             .order(created_at: :desc)
                             .limit(per_page)
    ProjectComment.from(comments, :comments).order(created_at: :asc)
  end

  def unassigned_users
    User
      .joins('INNER JOIN user_teams ON users.id = user_teams.user_id')
      .where('user_teams.team_id = ?', team)
      .where.not(confirmed_at: nil)
      .where('users.id NOT IN (?)',
             UserProject.where(project: self).select(:user_id).distinct)
  end

  def user_role(user)
    user_projects.find_by_user_id(user)&.role
  end

  def sorted_experiments(sort_by = :new, archived = false)
    sort = case sort_by
           when 'old' then { created_at: :asc }
           when 'atoz' then { name: :asc }
           when 'ztoa' then { name: :desc }
           when 'archived_new' then { archived_on: :desc }
           when 'archived_old' then { archived_on: :asc }
           else { created_at: :desc }
           end
    experiments.is_archived(archived).order(sort)
  end

  def archived_experiments
    experiments.is_archived(true)
  end

  def project_my_modules
    MyModule.where('"experiment_id" IN (?)', experiments.select(:id))
  end

  def space_taken
    st = 0
    project_my_modules.find_each do |my_module|
      st += my_module.space_taken
    end
    st
  end

  def assigned_repositories_and_snapshots
    live_repositories = Repository.assigned_to_project(self)
    snapshots = RepositorySnapshot.of_unassigned_from_project(self)
    (live_repositories + snapshots).sort_by { |r| r.name.downcase }
  end

  def my_modules_ids
    ids = active_experiments.map do |exp|
      exp.my_modules.pluck(:id) if exp.my_modules
    end
    ids.delete_if { |i| i.flatten.empty? }
    ids.join(', ')
  end

  def assigned_modules(user)
    role = user_role(user)
    if role.blank?
      MyModule.none
    elsif role == 'owner'
      project_my_modules
        .joins(:experiment)
        .where('experiments.archived=false')
        .where('my_modules.archived=false')

    else
      project_my_modules
        .joins(:user_my_modules)
        .joins(:experiment)
        .where('experiments.archived=false AND user_my_modules.user_id IN (?)',
               user.id)
        .where('my_modules.archived=false')
        .distinct
    end
  end

  def notifications_count(user)
    res = 0
    assigned_modules(user).find_each do |t|
      res += 1 if (t.is_overdue? || t.is_one_day_prior?) && !t.completed?
    end
    res
  end

  def comments
    project_comments
  end

  def generate_teams_export_report_html(
    user, team, html_title, obj_filenames = nil
  )
    ActionController::Renderer::RACK_KEY_TRANSLATION['warden'] ||= 'warden'
    proxy = Warden::Proxy.new({}, Warden::Manager.new({}))
    proxy.set_user(user, scope: :user, store: false)
    renderer = ApplicationController.renderer.new(warden: proxy)

    report = Report.generate_whole_project_report(self, user, team)

    page_html_string =
      renderer.render 'reports/new.html.erb',
                      locals: { export_all: true,
                                obj_filenames: obj_filenames },
                      assigns: { project: self, report: report }
    parsed_page_html = Nokogiri::HTML(page_html_string)
    parsed_html = parsed_page_html.at_css('#report-content')

    # Style tables (mimick frontend processing)

    tables = parsed_html.css('.hot-table-contents')
                        .zip(parsed_html.css('.hot-table-container'))
    tables.each do |table_input, table_container|
      table_vals = JSON.parse(table_input['value'])
      table_data = table_vals['data']
      table_headers = table_vals['headers']
      table_headers ||= ('A'..'Z').first(table_data[0].count)

      table_el = table_container
                 .add_child('<table class="handsontable"></table>').first

      # Add header row
      header_cell = '<th>'\
                      '<div class="relative">'\
                        '<span>%s</span>'\
                      '</div>'\
                    '</th>'
      header_el = table_el.add_child('<thead></thead>').first
      row_el = header_el.add_child('<tr></tr>').first
      row_el.add_child(format(header_cell, '')).first
      table_headers.each do |col|
        row_el.add_child(format(header_cell, col)).first
      end

      # Add body rows
      body_cell = '<td>%s</td>'
      body_el = table_el.add_child('<tbody></tbody>').first
      table_data.each.with_index(1) do |row, idx|
        row_el = body_el.add_child('<tr></tr>').first
        row_el.add_child(format(header_cell, idx)).first
        row.each do |col|
          row_el.add_child(format(body_cell, col)).first
        end
      end
    end

    ApplicationController.render(
      layout: false,
      locals: {
        title: html_title,
        content: parsed_html.children.map(&:to_s).join
      },
      template: 'team_zip_exports/report',
      current_user: user,
      current_team: team
    )
  ensure
    report.destroy if report.present?
  end

  private

  def project_folder_team
    return if project_folder.team_id == team_id

    errors.add(:project_folder, I18n.t('activerecord.errors.models.project.attributes.project_folder.team'))
  end

  def remove_project_folder
    self.project_folder = nil
  end
end
