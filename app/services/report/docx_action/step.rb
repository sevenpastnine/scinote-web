# frozen_string_literal: true

# rubocop:disable  Style/ClassAndModuleChildren
module Report::DocxAction::Step
  def draw_step(step, _children)
    step_type_str = step.completed ? 'completed' : 'uncompleted'
    user = step.completed || !step.changed? ? step.user : step.last_modified_by
    timestamp = step.completed ? step.completed_on : step.updated_at
    tables = step.tables
    assets = step.assets
    checklists = step.checklists
    comments = step.step_comments
    @docx.p I18n.t(
      "projects.reports.elements.step.#{step_type_str}.user_time",
      user: user.full_name,
      timestamp: I18n.l(timestamp, format: :full)
    )
    @docx.hr

    @docx.p do
      text I18n.t('projects.reports.elements.step.step_pos', pos: step.position_plus_one), bold: true, size: 26
      text ' ' + step.name, size: 26
      text ' '
      if step.completed
        text I18n.t('protocols.steps.completed'), color: '2dbe61'
      else
        text I18n.t('protocols.steps.uncompleted'), color: 'a0a0a0'
      end
    end
    if step.description.present?
      html = SmartAnnotations::TagToHtml.new(@user, @report_team, step.description).html
      html_to_word_converter(html)
    else
      @docx.p I18n.t 'projects.reports.elements.step.no_description'
    end

    tables.each do |table|
      draw_step_table(table)
    end

    checklists.each do |checklist|
      draw_step_checklist(checklist)
    end

    assets.each do |asset|
      draw_step_asset(asset)
    end

    draw_step_comments(comments, step)

    @docx.p
    @docx.p
  end
end
# rubocop:enable  Style/ClassAndModuleChildren
