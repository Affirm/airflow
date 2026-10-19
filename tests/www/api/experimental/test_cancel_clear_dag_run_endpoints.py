#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
"""Tests for the Affirm-only cancel_dag_run / clear_dag_run experimental endpoints."""

from __future__ import annotations

import json

import pytest

from airflow.api.common.trigger_dag import trigger_dag
from airflow.jobs.job import Job
from airflow.models import DagBag, DagRun, TaskInstance
from airflow.models.serialized_dag import SerializedDagModel
from airflow.settings import Session
from airflow.utils import timezone
from airflow.utils.state import DagRunState, State, TaskInstanceState

pytestmark = pytest.mark.db_test

DAG_ID = "example_bash_operator"
RUN_ID = "affirm_cancel_clear_run"


class TestCancelClearDagRunEndpoints:
    @pytest.fixture(scope="class", autouse=True)
    def _setup_session(self):
        session = Session()
        session.query(TaskInstance).delete()
        session.query(DagRun).delete()
        session.commit()
        session.close()
        dagbag = DagBag(include_examples=True)
        for dag in dagbag.dags.values():
            dag.sync_to_db()
            SerializedDagModel.write_dag(dag)

    @pytest.fixture(autouse=True)
    def _reset_test_session(self, experiemental_api_app):
        self.app = experiemental_api_app.test_client()
        yield
        session = Session()
        session.query(TaskInstance).delete()
        session.query(DagRun).delete()
        session.query(Job).delete()
        session.commit()
        session.close()

    def _post(self, endpoint, payload):
        return self.app.post(
            f"/api/experimental/dags/{DAG_ID}/{endpoint}",
            data=json.dumps(payload),
            content_type="application/json",
        )

    def _trigger(self):
        return trigger_dag(dag_id=DAG_ID, run_id=RUN_ID, execution_date=timezone.datetime(2024, 1, 1))

    @pytest.mark.parametrize("endpoint", ["cancel_dag_run", "clear_dag_run"])
    def test_missing_run_id(self, endpoint):
        response = self._post(endpoint, {})
        assert 400 == response.status_code
        assert {"error": "Missing run_id"} == json.loads(response.data.decode("utf-8"))

    @pytest.mark.parametrize("endpoint", ["cancel_dag_run", "clear_dag_run"])
    def test_unknown_run_id(self, endpoint):
        response = self._post(endpoint, {"run_id": "does_not_exist"})
        assert 400 == response.status_code
        assert "No matching dagrun" in json.loads(response.data.decode("utf-8"))["error"]

    def test_cancel_dag_run(self):
        self._trigger()
        session = Session()
        dag_run = session.query(DagRun).filter_by(dag_id=DAG_ID, run_id=RUN_ID).one()
        tis = dag_run.get_task_instances(session=session)
        running_ti, *other_tis = tis
        job = Job()
        job.state = State.RUNNING
        session.add(job)
        session.flush()
        running_ti.state = TaskInstanceState.RUNNING
        running_ti.job_id = job.id
        session.merge(running_ti)
        session.commit()
        job_id, running_key = job.id, running_ti.key
        session.close()

        response = self._post("cancel_dag_run", {"run_id": RUN_ID})

        assert 200 == response.status_code
        assert json.loads(response.data.decode("utf-8"))["message"].startswith("Cancelled ")
        session = Session()
        dag_run = session.query(DagRun).filter_by(dag_id=DAG_ID, run_id=RUN_ID).one()
        assert DagRunState.FAILED == dag_run.state
        states = {ti.key.task_id: ti.state for ti in dag_run.get_task_instances(session=session)}
        assert TaskInstanceState.SHUTDOWN == states.pop(running_key.task_id)
        assert {TaskInstanceState.FAILED} == set(states.values())
        assert len(states) == len(other_tis)
        assert State.SHUTDOWN == session.get(Job, job_id).state
        session.close()

    def test_cancel_finished_dag_run_is_rejected(self):
        """Regression for State.finished() raising TypeError on frozenset (A3)."""
        self._trigger()
        session = Session()
        dag_run = session.query(DagRun).filter_by(dag_id=DAG_ID, run_id=RUN_ID).one()
        dag_run.state = DagRunState.SUCCESS
        session.commit()
        session.close()

        response = self._post("cancel_dag_run", {"run_id": RUN_ID})

        assert 400 == response.status_code
        assert "finished state" in json.loads(response.data.decode("utf-8"))["error"]

    def test_clear_dag_run(self):
        self._trigger()
        session = Session()
        dag_run = session.query(DagRun).filter_by(dag_id=DAG_ID, run_id=RUN_ID).one()
        dag_run.state = DagRunState.FAILED
        for ti in dag_run.get_task_instances(session=session):
            ti.state = TaskInstanceState.FAILED
            session.merge(ti)
        session.commit()
        session.close()

        response = self._post("clear_dag_run", {"run_id": RUN_ID})

        assert 200 == response.status_code
        assert json.loads(response.data.decode("utf-8"))["message"].startswith("Cleared ")
        session = Session()
        dag_run = session.query(DagRun).filter_by(dag_id=DAG_ID, run_id=RUN_ID).one()
        assert DagRunState.QUEUED == dag_run.state
        assert {None} == {ti.state for ti in dag_run.get_task_instances(session=session)}
        session.close()
