# Two layers, loaded in order.
#
# 1. THE BASELINE - forked from `etp_assessment_pro` at 19.0.1.135.0 and owned
#    outright; nothing here inherits from upstream any more, so upstream can be
#    decommissioned without touching a line of it.
#
# 2. OUR CHANGES - the `*_api.py` files, kept separate so the diff against the
#    fork point stays readable. They `_inherit` models THIS addon defines, so
#    they must load after the baseline.
from . import tag
from . import question
from . import question_image
from . import question_video
from . import question_dimension
from . import question_type
from . import prompt
from . import assessment_similarity
from . import prompt_question_dimension
from . import bank_import
from . import bank_import_wizard
from . import simple_import
from . import res_config_settings
# Which rung of the access ladder an account is on. One answer, shared by every
# gate and by the candidate-provisioning path; see its docstring for the four
# copies it replaces.
from . import res_users
from . import llm_usage
from . import scoring_cache
# The nine crons' lease rows, used only in lease lock mode (services/locks.py).
from . import cron_lease
from . import hr_applicant
from . import assessment
from . import dashboard
from . import llm_dashboard

# --- our changes on top of the fork ---
from . import ir_attachment
from . import ir_http
from . import assessment_api

# Form Studio's storage, a model with no upstream counterpart.
from . import studio_form

# Reusable task templates for generation - the shape of a task, saved once and
# generated from many times. See task_template.py's own docstring.
from . import task_template
from . import delete_wizard
from . import release_wizard
