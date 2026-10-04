<script setup>
import { computed, onMounted, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import smtpAPI from 'dashboard/api/aberaSmtp';
import NextButton from 'dashboard/components-next/button/Button.vue';
import SectionLayout from './SectionLayout.vue';

const { t } = useI18n();
const available = ref(false);
const configured = ref(false);
const busy = ref(false);
const form = reactive({
  address: '',
  port: 587,
  username: '',
  password: '',
  sender: '',
  authentication: 'login',
  security: 'starttls',
});
const fields = computed(() => [
  {
    key: 'address',
    type: 'text',
    label: t('GENERAL_SETTINGS.SMTP.FIELDS.ADDRESS'),
  },
  {
    key: 'port',
    type: 'number',
    label: t('GENERAL_SETTINGS.SMTP.FIELDS.PORT'),
  },
  {
    key: 'username',
    type: 'text',
    label: t('GENERAL_SETTINGS.SMTP.FIELDS.USERNAME'),
  },
  {
    key: 'password',
    type: 'password',
    label: t('GENERAL_SETTINGS.SMTP.FIELDS.PASSWORD'),
  },
  {
    key: 'sender',
    type: 'email',
    label: t('GENERAL_SETTINGS.SMTP.FIELDS.SENDER'),
  },
]);
const authenticationMethods = computed(() => [
  { value: 'login', label: t('GENERAL_SETTINGS.SMTP.AUTH.LOGIN') },
  { value: 'plain', label: t('GENERAL_SETTINGS.SMTP.AUTH.PLAIN') },
  { value: 'cram_md5', label: t('GENERAL_SETTINGS.SMTP.AUTH.CRAM_MD5') },
]);
const testLabels = computed(() => ({
  completed: t('GENERAL_SETTINGS.SMTP.TEST_SUCCESS'),
  failed: t('GENERAL_SETTINGS.SMTP.ERROR'),
  pending: t('GENERAL_SETTINGS.SMTP.TEST_PENDING'),
  running: t('GENERAL_SETTINGS.SMTP.TEST_PENDING'),
}));

onMounted(async () => {
  try {
    const { data } = await smtpAPI.get();
    configured.value = data.configured;
    Object.keys(form).forEach(key => {
      if (data[key] !== undefined) form[key] = data[key];
    });
    available.value = true;
  } catch (error) {
    if (error.response?.status !== 404)
      useAlert(t('GENERAL_SETTINGS.SMTP.ERROR'));
  }
});

async function pollTest(jobId, attempts = 20) {
  await new Promise(resolve => {
    setTimeout(resolve, 2000);
  });
  const { data } = await smtpAPI.testStatus(jobId);
  if (['completed', 'failed'].includes(data.state) || attempts === 1) {
    return data.state;
  }
  return pollTest(jobId, attempts - 1);
}

async function submit(test = false) {
  busy.value = true;
  try {
    if (test) {
      const { data } = await smtpAPI.test();
      const state = await pollTest(data.jobId);
      useAlert(testLabels.value[state]);
      return;
    }
    await smtpAPI.save(form);
    configured.value = true;
    form.password = '';

    useAlert(t('GENERAL_SETTINGS.SMTP.SAVED'));
  } catch (error) {
    useAlert(error.response?.data?.error || t('GENERAL_SETTINGS.SMTP.ERROR'));
  } finally {
    busy.value = false;
  }
}
</script>

<template>
  <div>
    <SectionLayout
      v-if="available"
      :title="t('GENERAL_SETTINGS.SMTP.TITLE')"
      :description="t('GENERAL_SETTINGS.SMTP.DESCRIPTION')"
      with-border
    >
      <p v-if="!configured" role="status" class="text-n-amber-11">
        {{ t('GENERAL_SETTINGS.SMTP.PENDING') }}
      </p>
      <form class="grid gap-4" @submit.prevent="submit()">
        <label
          v-for="field in fields"
          :key="field.key"
          class="grid gap-2 text-n-slate-12"
        >
          {{ field.label }}
          <input
            v-model="form[field.key]"
            :type="field.type"
            :required="field.key !== 'password' || !configured"
            :autocomplete="field.key === 'password' ? 'new-password' : 'off'"
            class="rounded-lg border border-n-weak bg-n-background p-3 text-n-slate-12"
          />
        </label>
        <label class="grid gap-2 text-n-slate-12">
          {{ t('GENERAL_SETTINGS.SMTP.FIELDS.SECURITY') }}
          <select
            v-model="form.security"
            class="rounded-lg border border-n-weak bg-n-background p-3"
          >
            <option value="starttls">
              {{ t('GENERAL_SETTINGS.SMTP.STARTTLS') }}
            </option>
            <option value="ssl">{{ t('GENERAL_SETTINGS.SMTP.TLS') }}</option>
          </select>
        </label>
        <label class="grid gap-2 text-n-slate-12">
          {{ t('GENERAL_SETTINGS.SMTP.FIELDS.AUTHENTICATION') }}
          <select
            v-model="form.authentication"
            class="rounded-lg border border-n-weak bg-n-background p-3"
          >
            <option
              v-for="method in authenticationMethods"
              :key="method.value"
              :value="method.value"
            >
              {{ method.label }}
            </option>
          </select>
        </label>
        <div class="flex gap-3">
          <NextButton type="submit" :is-loading="busy">
            {{ t('GENERAL_SETTINGS.SMTP.SAVE') }}
          </NextButton>
          <NextButton
            type="button"
            :disabled="!configured || busy"
            @click="submit(true)"
          >
            {{ t('GENERAL_SETTINGS.SMTP.TEST') }}
          </NextButton>
        </div>
      </form>
    </SectionLayout>
  </div>
</template>
