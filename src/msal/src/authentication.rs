use pyo3::prelude::*;
use pyo3::types::IntoPyDict;
use pyo3::types::PyString;
use pyo3::types::PyTuple;
use pyo3::types::PyList;
use pyo3::types::PyDict;
use std::collections::HashMap;
use log::debug;

use rand::Rng;
use rand_chacha::ChaCha8Rng;
use rand::SeedableRng;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

pub const INVALID_CRED: u32 = 0xC3CE;
pub const REQUIRES_MFA: u32 = 0xC39C;
pub const INVALID_USER: u32 = 0xC372;
pub const NO_CONSENT:   u32 = 0xFDE9;
pub const NO_SECRET:    u32 = 0x6AD09A;

pub struct PublicClientApplication {
    app: Py<PyAny>
}

fn extract_pydict_as_hashmap(obj: &PyDict) -> (HashMap<String, String>, Vec<u32>) {
    let mut res = HashMap::new();
    let mut err: Vec<u32> = vec![];
    for (key, val) in obj.iter() {
        let py_key: &PyString = key.extract().expect("Failed parsing dict key");
        let k: String = py_key.to_string_lossy().into_owned();
        if k == "error_codes" {
            let error_codes: &PyList = val.extract().expect("Failed parsing error list");
            let vec_error_codes: Vec<u32> = error_codes.extract().expect("Failed parsing error list");
            err.extend(vec_error_codes);
            continue;
        }
        let py_val: &PyString = match val.extract() {
            Ok(val) => val,
            Err(error) => {
                debug!("Unable to extract key '{}': {}", k, error);
                continue;
            }
        };
        let v: String = py_val.to_string_lossy().into_owned();
        res.insert(k, v);
    }
    (res, err)
}

impl PublicClientApplication {
    pub fn new(app_id: &str, authority_url: &str) -> PublicClientApplication {
        Python::with_gil(|py| {
            let msal = PyModule::import(py, "msal")
                .expect("Failed importing msal");
            let kwargs = [("authority", authority_url)].into_py_dict(py);
            let func: Py<PyAny> = msal.getattr("PublicClientApplication")
                .expect("Failed loading the PublicClientApplication")
                .into();
            let py_app_id: &PyString = PyString::new(py, app_id);
            let args: &PyTuple = PyTuple::new(py, vec![py_app_id]);
            let py_app = func.call(py, args, Some(kwargs))
                .expect("Initialization of PublicClientApplication failed");
            PublicClientApplication {
                app: py_app
            }
        })
    }

    pub fn acquire_token_by_username_password(&self, username: &str, password: &str, scopes: Vec<&str>) -> (HashMap<String, String>, Vec<u32>) {
        Python::with_gil(|py| {
            let func: Py<PyAny> = self.app.getattr(py, "acquire_token_by_username_password")
                .expect("Failed loading function acquire_token_by_username_password")
                .into();
            let py_username: &PyString = PyString::new(py, username);
            let py_password: &PyString = PyString::new(py, password);
            let py_scopes: &PyList = PyList::new(py, scopes);
            let largs: &PyList = PyList::new(py, vec![py_username, py_password]);
            largs.append(py_scopes)
                .expect("Failed appending scopes to the args list");
            let args: &PyTuple = PyTuple::new(py, largs);
            extract_pydict_as_hashmap(
                func.call1(py, args)
                .expect("Failed calling acquire_token_by_username_password")
                .downcast(py)
                .expect("Failed downcasting the PyAny to a PyDict")
            )
        })
    }

    pub fn gen_unique_account_uid(&self, oid: &str) -> u32 {
        let mut hash = DefaultHasher::new();
        oid.hash(&mut hash);
        let seed = hash.finish();
        let mut rng = ChaCha8Rng::seed_from_u64(seed);

        rng.gen_range(10000..=4294967295)
    }

    pub fn get_accounts(&self) -> Vec<HashMap<String, String>> {
        let mut accounts: Vec<HashMap<String, String>> = Python::with_gil(|py| {
            let func: Py<PyAny> = self.app.getattr(py, "get_accounts")
                .expect("Failed loading function get_accounts")
                .into();
            func.call0(py)
                .expect("Failed calling get_accounts")
                .extract(py)
                .expect("Extraction to a list of hashmaps failed")
        });
        for account in accounts.iter_mut() {
            let oid = account.get("local_account_id").expect("Failed fetching oid");
            let uid_str = self.gen_unique_account_uid(oid).to_string();
            account.insert("uid".to_string(), uid_str);
        }
        accounts
    }

    pub fn get_account(&self, account_id: &String) -> Option<HashMap<String, String>> {
        self.get_accounts()
            .iter()
            .find(|tok| tok.get("username").expect("Failed to find username in account") == account_id)
            .cloned()
    }
}
