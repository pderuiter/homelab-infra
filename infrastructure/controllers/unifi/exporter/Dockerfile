FROM python:3.12-alpine

WORKDIR /app
RUN addgroup -S app && adduser -S app -G app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

USER app
EXPOSE 9131
ENTRYPOINT ["python", "-u", "main.py"]
