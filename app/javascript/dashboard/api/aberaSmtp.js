/* global axios */
import ApiClient from './ApiClient';

class AberaSmtpAPI extends ApiClient {
  constructor() {
    super('abera_smtp_settings', { accountScoped: true });
  }

  save(smtp) {
    return axios.patch(this.url, { smtp });
  }

  test() {
    return axios.post(`${this.url}/test`);
  }

  testStatus(jobId) {
    return axios.get(`${this.url}/test_status`, { params: { jobId } });
  }
}

export default new AberaSmtpAPI();
