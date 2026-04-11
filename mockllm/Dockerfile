FROM python:3.10-slim
RUN pip install --no-cache-dir mockllm
COPY responses.yml /app/responses.yml
WORKDIR /app
EXPOSE 4010
CMD ["mockllm", "start", "--host", "0.0.0.0", "--port", "4010", "--responses", "responses.yml"]
